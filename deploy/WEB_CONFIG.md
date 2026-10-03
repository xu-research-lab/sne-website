# Server reference

How the server is put together and why, for when something misbehaves or needs
changing. **The steps for deploying and updating are in the
[README](../README.md); this document does not repeat them.**

---

## What runs, and what does not

```
                    visitor's browser
                    ├─ all model inference (onnxruntime-web, WebAssembly)
                    ├─ all preprocessing
                    └─ all rendering
                             │
   nginx (host) ─────────────┼──────────────────────────────────────
   ├─ /, /atlas/, /dysbiosis/, /download/      static files
   ├─ /data/*                                  static files
   └─ /map, /health ───────► map service (127.0.0.1:8000)
                             └─ vsearch against otu_refseqs.fasta, or
                                atlas_refseqs.fasta for ?db=atlas
```

The split is what makes a 1-core host enough. The browser pays for the neural
network — 4.7 MB downloaded once, then cached — and the server does the one
thing a browser cannot: align a visitor's sequences against the reference OTUs.
A few hundred sequences take well under a second.

**The dysbiosis database holds 8,850 sequences, not 14,093.** The model's
vocabulary is 14,019 ids, and only 8,850 of them have both a sequence and a
trained vector. Mapping a read to anything outside that set would hand the
model an OTU it scores as absent: a silently wrong answer rather than an error.
The atlas database is separate and does cover all 14,093, because the atlas
only has to find a card to open.

---

## Sizing

| Resource | Minimum | Notes |
|---|---|---|
| vCPU | 1 | vsearch is single-threaded, and the container is capped at one core |
| RAM | 2 GB | nginx ~50 MB, map service ~150 MB under load, page cache the rest |
| Disk | 20 GB | site 84 MB, reference databases 30 MB, OS and logs the rest |

Bandwidth per visitor, first visit; everything is cached afterwards:

| Page | Transferred |
|---|---|
| Home, download | < 100 kB |
| Atlas | ~4.8 MB gzipped |
| Dysbiosis | ~9.2 MB gzipped, of which 3.0 MB is the ONNX Runtime WebAssembly |

The dysbiosis page is heavy, deliberately. The alternative is running inference
on the server, which multiplies the cores needed by the number of people
visiting at once. The runtime is shared across visitors through the browser
cache, so its cost is paid once per visitor rather than once per sample.
Quantising the graph to int8 would take the model from 4.7 MB to roughly
1.2 MB at some cost in accuracy — a deliberate change, with the regression
tests re-run, not a default.

---

## The nginx config

`nginx-http.conf` is the file to install; certbot writes the TLS server block
into it. `nginx.conf` is the same configuration with TLS written out by hand,
for a deployment that manages its own certificates. Both expect the site at
`/srv/microbial/site`.

### One line that cannot live in the file

```nginx
limit_req_zone $binary_remote_addr zone=map_limit:10m rate=10r/m;
```

Rate-limit zones are only valid in nginx's `http` block, so this goes in
`/etc/nginx/nginx.conf`, not in the site config. Without it nginx refuses to
start, naming the `limit_req` line in the site config.

### What each location does

| Location | Behaviour | Why |
|---|---|---|
| `/assets/` | `expires epoch` | Filenames are not content-hashed, so a long cache kept visitors on old CSS and JS for a month after every deploy. Cache busting is the `?v=` query instead |
| `/data/` | `expires 7d` | Large, and changes only when the data is rebuilt |
| `*.wasm` | `expires 30d`, `Content-Type: application/wasm` | onnxruntime instantiates it by streaming, which requires the exact MIME type. Anything else kills the dysbiosis page with no useful error |
| `/data/download/` | `expires 7d`, plus `Access-Control-Allow-Origin: *` | So the files can be loaded by external tools |
| `= /map` | proxy to `127.0.0.1:8000`, `limit_req` 10/min burst 5, 429 on refusal, 12 MB body cap | The only endpoint that costs CPU. The service caps uploads at 10 MB itself; nginx's 12 MB leaves room for the multipart envelope |
| `= /health` | proxy, no rate limit | So a monitor can poll it |
| `/` and `= /index.html` | `expires -1` | HTML must revalidate, or a deploy is invisible |
| fonts, images | `expires 30d` | They change with the design, which is rare |

`add_header` is inherited only by locations that declare none of their own.
That is why every cache lifetime above is written as `expires` rather than
`add_header Cache-Control`, and why `/data/download/`, which needs a CORS
header, repeats the three security headers the server block sets.

---

## The map service

FastAPI in front of vsearch. It binds to `127.0.0.1:8000` only: nginx is the
single public entry point, and vsearch with no rate limit is not something to
expose.

| Setting | Value | Where |
|---|---|---|
| Upload cap | 10 MB | `MAX_BYTES` in `server/app/main.py` |
| Sequence cap | 5,000 | `MAX_SEQUENCES` |
| Identity | 0.97 | `IDENTITY`, matching the OTU definition |
| vsearch timeout | 120 s | `VSEARCH_TIMEOUT_SECONDS` |
| Rate limit | 10/min per IP | in nginx, and again in the service |

Three environment variables locate its data: `OTU_REFSEQS`, `ATLAS_REFSEQS` and
`VSEARCH_BINARY`. They are set in `docker-compose.yml` and in
`microbial-map.service`; if either path is wrong, `/health` reports
`database_present: false` and `/map` answers 503.

### Running it without Docker

The README uses Docker. The systemd unit is the alternative, and it needs
vsearch installed system-wide, which most distributions do not package:

```bash
sudo useradd --system --home /srv/microbial --shell /usr/sbin/nologin microbial
sudo -u microbial python3 -m venv /srv/microbial/venv
sudo -u microbial /srv/microbial/venv/bin/pip install -r /srv/microbial/server/requirements.txt

sudo wget -O /tmp/vsearch.tar.gz \
  https://github.com/torognes/vsearch/releases/download/v2.28.1/vsearch-2.28.1-linux-x86_64.tar.gz
sudo tar -xzf /tmp/vsearch.tar.gz -C /tmp
sudo install -m 0755 /tmp/vsearch-2.28.1-linux-x86_64/bin/vsearch /usr/local/bin/vsearch

sudo install -m 0644 /srv/microbial/deploy/microbial-map.service \
  /etc/systemd/system/microbial-map.service
sudo systemctl daemon-reload && sudo systemctl enable --now microbial-map
curl -s localhost:8000/health
```

---

## Operations

### Logs

```bash
docker compose -f deploy/docker-compose.yml logs -f map   # Docker
journalctl -u microbial-map -f                            # systemd
sudo tail -f /var/log/nginx/access.log
grep -c ' 429 ' /var/log/nginx/access.log                 # how often the limit bites
```

Docker keeps three 10 MB log files per service; systemd uses the journal's own
limits. Neither needs rotation set up.

### Rebuilding the reference databases

Only when the vocabulary or the atlas OTUs change:

```bash
.venv-export/bin/python script/web_export/export_assets.py
rsync -av data/server/ server:/srv/microbial/data/
curl -s localhost:8000/health          # on the server, after a restart
```

Docker reads them through a read-only bind mount, so a restart picks up the new
files: `docker compose -f deploy/docker-compose.yml restart map`.

### Certificates

certbot installs a renewal timer when it issues the certificate. Check it with
`systemctl list-timers | grep certbot`, and prove renewal works with
`sudo certbot renew --dry-run`. Renewal validates over HTTP-01, so port 80 must
stay open and reachable even after the site moves to HTTPS.

### Backups

Nothing on the server is stateful: no database, no uploads, no sessions. What
is worth keeping lives on the build machine and in git. Rebuilding the server
is the README's first-deployment section, start to finish.

---

## Known limits, and what not to quietly drop

**8,850 usable OTUs, not 14,093.** A sample whose community falls mostly
outside that set is scored with most positions masked. The result page reports
how many of a sample's taxa the model could see; that line is the visitor's
only warning and should not be removed.

**Leave-one-disease-out AUC 0.64.** That is the number for a disease the model
has not seen, against 0.67 for the pooled leave-one-disease-out model in the
paper. The ensemble's 0.7976 on the cohort it trained on is *not* a
generalisation estimate — `metrics.json` carries it as `reference_auc` with a
note saying so, and the site does not show it.

**The percentile is not a probability.** Nothing on the site should say
"risk", "probability of disease" or "diagnosis" about a sample. The pages
enforce this in their copy; the dysbiosis page carries the research-use notice.

**Trait values have three different origins.** BacDive values are measured;
Traitar values are called from a genome, which is itself an inference; the rest
are predicted from the embedding. The card labels each one, and a trait AUC
says how well the embedding reproduces Traitar, not an experiment.

**HDF5 BIOM files cannot be read in the browser.** The page says so and points
to `biom convert --to-tsv` or the FASTA route. A WebAssembly HDF5 reader would
fix it at the cost of another megabyte of runtime.

**Browsers without WebAssembly SIMD need their own runtime build.** Safari
before 16.4, Chrome before 91 and Firefox before 89 fetch `ort-wasm.wasm`
rather than `ort-wasm-simd.wasm`. All three builds must be deployed;
`script/check_vendor.sh` verifies they are present and at the pinned version.
