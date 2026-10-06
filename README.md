# SNEs website

The public site for social niche embeddings of the human gut microbiome:
<https://sne.xulab.science>.

Everything a visitor sees is a static file. The one exception is `/map`, which
aligns uploaded sequences against the reference OTUs; it is the only process
running on the server. The dysbiosis model does **not** run on the server — it
is downloaded and executed in the visitor's browser, which is what lets a
1-core host serve any number of people.

| Page | What it does |
|---|---|
| `/` | Summary, the key numbers, and how to cite |
| `/atlas/` | 14,093 gut OTUs on a map. Search by family, genus, species, OTU identifier, or a 16S sequence. Each card shows ecological and phylogenetic neighbours side by side, then the traits |
| `/dysbiosis/` | Scores one faecal sample against a reference cohort of 10,276, in the browser. Input is an OTU table (six one-click examples) or rep-seqs plus counts |
| `/download/` | The data files, the version table, and the metadata column reference |

---

## Jump to what you need

| I want to… | Go to |
|---|---|
| Change page text, styling or JavaScript | [Update the site](#update-the-site) |
| Rebuild the data the site serves | [Rebuild the data](#rebuild-the-data) |
| Set up a new server from scratch | [First deployment](#first-deployment) |
| Run the site on my laptop | [Local development](#local-development) |
| Work out why something broke | [Troubleshooting](#troubleshooting) |

---

## How it runs

```
visitor's browser
├─ the dysbiosis model (onnxruntime-web, WebAssembly, ~10 MB once)
├─ all preprocessing and every figure
└─ fetches static files only
         │
         ▼
nginx on the server
├─ /, /atlas/, /dysbiosis/, /download/   files from /srv/microbial/site/
├─ /data/*                               files from /srv/microbial/site/data/
└─ /map, /health  ──►  map service on 127.0.0.1:8000
                       └─ vsearch against /srv/microbial/data/*.fasta
```

Nothing on the server is stateful: no database, no uploads directory, no
sessions. `/map` writes a temporary file, runs vsearch, deletes it, answers.
Rebuilding the whole server is a few `rsync` commands.

**Server size.** 1 vCPU, 2 GB RAM, 20 GB disk is enough. The current host is an
Alibaba Cloud ECS instance in Silicon Valley.

**Repository layout.**

```
web/                 the site itself: HTML, CSS, ES modules, vendored libraries
data/web/            everything served under /data/ (53 MB, built offline)
data/server/         the vsearch databases (30 MB, never served to browsers)
data/silva_tree/     the SILVA reference tree, input to the neighbour export
script/              research notebooks and the export pipeline
  web_export/        the build steps, in order; see its own README
server/              the FastAPI + vsearch service behind /map
tests/js/            the browser code checked against Python
deploy/              nginx configs, Docker compose, systemd unit
```

---

## Update the site

The common case: you edited something under `web/`.

```bash
# 1. On your machine: check it still works, then push.
cd tests/js && npm test && cd ../..
git add web && git commit -m "…" && git push

# 2. On the server:
cd ~/sne-website && git pull
script/check_vendor.sh                                      # see the warning below
sudo rsync -av --delete --exclude=/data web/ /srv/microbial/site/
```

**If you changed a file under `web/assets/`,** bump its `?v=` number in the page
that loads it, and in any module that imports it. Browsers hold on to the old
copy otherwise. For example, after editing `card.js`:

```
web/assets/js/atlas.js:   import { renderCard } from './card.js?v=9';   ← was v=8
web/atlas/index.html:     <script src="/assets/js/atlas.js?v=9">        ← was v=8
```

**If you changed anything in `data/web/`,** that directory is a separate copy:

```bash
sudo rsync -av --delete data/web/ /srv/microbial/site/data/
```

**`script/check_vendor.sh` is not optional after a pull.** The onnxruntime
JavaScript loader is committed, but the three `.wasm` files beside it are 10 MB
each and are not in git. A pull can therefore leave a new loader next to the
previous release's WebAssembly, and onnxruntime then fails in the browser
without naming a version. The script compares both against the pin in
`script/fetch_vendor.sh` and tells you to run it if they disagree.

---

## Rebuild the data

Only when the model, the embeddings, the traits or the taxonomy change. This
runs on the machine that has the BIOM tables and the fold checkpoints, never on
the server. The checkpoints (`data/healthy_disease_predict/model/`, 2.4 GB) are
not in git: they are the training run's output, and the site ships only the
ONNX graph exported from them.

```bash
python -m venv --system-site-packages .venv-export
.venv-export/bin/pip install "onnx==1.15.0" "onnxruntime==1.16.3"
```

Then run the eight steps in [`script/web_export/README.md`](script/web_export/README.md),
in order. The order matters: step 4 rewrites `meta.json`, and step 8 replaces
the phylogenetic neighbours that step 1 wrote. That README says what each
script reads and writes.

`export_dysbiosis.py` takes about 35 minutes and checks itself before writing
anything: it reproduces the training run's own predictions for all 10,276
reference samples, then checks onnxruntime against PyTorch. **If it fails, do
not deploy its output.**

Afterwards, copy the new data to the server with the `data/web/` command above.

---

## First deployment

What you need: a Linux server with root, a domain pointing at it, and ports 80
and 443 open (on Alibaba Cloud, in the security group as well as the firewall).

### 1. Copy the files

```bash
ssh you@server 'sudo mkdir -p /srv/microbial && sudo chown $USER /srv/microbial'

rsync -av --delete --exclude=/data web/  you@server:/srv/microbial/site/
rsync -av --delete data/web/             you@server:/srv/microbial/site/data/
rsync -av --delete data/server/          you@server:/srv/microbial/data/
rsync -av --delete server/               you@server:/srv/microbial/server/
rsync -av --delete deploy/               you@server:/srv/microbial/deploy/
```

The resulting layout:

```
/srv/microbial/
├── site/            ← web/        nginx serves this
│   └── data/        ← data/web/
├── data/            ← data/server/  the vsearch databases, outside the web root
├── server/          ← server/
└── deploy/          ← deploy/
```

One `rsync` per source. A trailing slash copies a directory's *contents*, so
combining sources would spill them into `/srv/microbial/` and `--delete` would
then erase `site/`.

### 2. Start the mapping service

```bash
sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker "$USER"        # then log out and back in
cd /srv/microbial && docker compose -f deploy/docker-compose.yml up -d --build

curl -s localhost:8000/health          # both databases must report true
```

A systemd unit is available instead of Docker; see
[`deploy/WEB_CONFIG.md`](deploy/WEB_CONFIG.md). Either way the service listens
on `127.0.0.1:8000` only — nginx is the single public entry point, and vsearch
without a rate limit is not something to expose.

### 3. Install nginx

The rate-limit zone has to live in the `http` block, so add one line to
`/etc/nginx/nginx.conf`:

```nginx
limit_req_zone $binary_remote_addr zone=map_limit:10m rate=10r/m;
```

Then install the site config and point it at your domain:

```bash
sudo apt install -y nginx
sudo cp /srv/microbial/deploy/nginx-http.conf \
        /etc/nginx/sites-available/microbial-embeddings
sudo sed -i 's/server_name _;/server_name your.domain;/' \
        /etc/nginx/sites-available/microbial-embeddings
sudo ln -sf /etc/nginx/sites-available/microbial-embeddings \
            /etc/nginx/sites-enabled/microbial-embeddings
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

The site is now live over HTTP. `deploy/nginx.conf` is the same thing with a
TLS block written out by hand; you do not need it if you use certbot below.

### 4. Get a certificate

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d your.domain --redirect --agree-tos -m you@example.org
```

This validates over HTTP-01, writes the TLS server block into the config you
just installed, adds the HTTP→HTTPS redirect, and installs a renewal timer.
Confirm renewal works:

```bash
sudo certbot renew --dry-run
```

### 5. Check the deployment

Each command catches a different class of mistake.

```bash
# The service is up and can see its databases.
curl -s https://your.domain/health | python3 -m json.tool

# Every file the manifest promises is actually served.
curl -s https://your.domain/data/manifest.json \
  | python3 -c "import json,sys; [print(f['file']) for f in json.load(sys.stdin)['files']]" \
  | while read -r f; do
      code=$(curl -s -o /dev/null -w '%{http_code}' "https://your.domain/data/$f")
      [ "$code" = 200 ] || echo "MISSING $f ($code)"
    done

# Compression is on: otus.json is 16 MB raw and should arrive near 1 MB.
curl -s -H 'Accept-Encoding: gzip' -o /dev/null -w '%{size_download}\n' \
  https://your.domain/data/otus.json

# All three WebAssembly builds are present and typed application/wasm. The
# non-SIMD one is the build Safari before 16.4 uses; a 404 here leaves the
# dysbiosis page dead with "no available backend found".
for f in ort-wasm.wasm ort-wasm-simd.wasm ort-wasm-simd-threaded.wasm; do
  curl -sI "https://your.domain/assets/vendor/ort/$f" | head -1
done

# /map round-trips: sequences taken from the database must come back as
# themselves, not merely as something.
head -c 40000 /srv/microbial/data/otu_refseqs.fasta > /tmp/probe.fasta
curl -s -F "rep_seqs=@/tmp/probe.fasta" https://your.domain/map | python3 -c "
import json, sys
p = json.load(sys.stdin)
bad = [(q, s) for q, s in p['mapping'].items() if q != s]
assert p['mapped'] == p['total'] and not bad, bad[:3]
print(p['mapped'], 'of', p['total'], 'mapped, each to itself')"
```

Then click through it once: search the atlas and open a card, click a point on
the map, run a dysbiosis example, and upload the two example files from
`/download/`.

---

## Local development

```bash
ln -sfn ../data/web web/data        # serves the built data at /data/
cd web && python3 -m http.server 8080
```

`web/data` is a symlink and is deliberately not committed: `rsync --delete`
would otherwise carry it to the server and replace the real data directory
with a link.

The `/map` endpoint is needed only for the sequence routes:

```bash
cd server
OTU_REFSEQS=../data/server/otu_refseqs.fasta \
ATLAS_REFSEQS=../data/server/atlas_refseqs.fasta \
VSEARCH_BINARY=/path/to/vsearch \
python -m uvicorn app.main:app --port 8000
```

---

## Tests

```bash
cd tests/js && npm test             # four browser-code suites
cd server && python -m pytest tests -v
```

What they protect, in order of how much it would hurt to lose:

- **`preprocess.test.mjs`** — the site re-implements the paper's preprocessing
  in JavaScript. A mistake there produces a plausible wrong score rather than
  an error, so this checks it against Python on fixture samples.
- **`table.test.mjs`** — the shapes count tables actually arrive in: the banner
  `biom convert` writes, a table transposed in a spreadsheet, a row longer than
  its header. The parser is the first thing a visitor's file meets.
- **`traits.test.mjs`** — that each trait's probability block lines up with the
  OTUs the card reads it for. A misaligned read draws a plausible plot from
  another trait's numbers, which is how an earlier offset bug went unnoticed.
- **`scatter.test.mjs`** — that a click on the map selects the point drawn
  under the cursor, at several zoom levels and canvas shapes.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Dysbiosis page: "no available backend found" | A `.wasm` file is missing, most often the non-SIMD build Safari < 16.4 needs | `script/fetch_vendor.sh`, then rsync `web/` |
| Dysbiosis page: "the inference runtime could not be loaded" | `ort.min.js` did not load: a blocked request, or a redeploy caught mid-flight | Reload; if it persists, check the file is served |
| An edit to CSS or JS does not appear | The browser is holding the old copy | Bump the `?v=` number, then hard-reload (Ctrl+Shift+R) |
| `/map` answers 503 | The service cannot see its FASTA databases | `curl localhost:8000/health`, check the paths and the bind mount |
| `/map` answers 429 | The rate limit: 10 requests per minute per IP | Expected under load; otherwise raise `rate=` in the `limit_req_zone` line in `/etc/nginx/nginx.conf` |
| nginx will not start after a config change | Usually `limit_req_zone` missing from the `http` block | `sudo nginx -t` names the line |
| The atlas search finds nothing for a species | Only 1,245 of 14,093 OTUs carry a species name in SILVA | Search the genus instead |

---

## Three things to know before reading the code

**The model knows 8,850 OTUs, not 14,093.** The atlas covers all 14,093 OTUs
that have an embedding. The dysbiosis model uses embeddings retrained without
the disease studies (the paper's Methods), and its vocabulary of 14,019 ids
has an embedding for only 8,850 of them. The rest carry no
information for the model, and the dysbiosis page does not list them among the
contributing taxa.

**Quote AUC 0.64, not 0.80.** The deployed model averages thirteen
leave-one-disease-out folds. Twelve of the thirteen saw any given reference
sample's disease during training, so the ensemble separates the reference
cohort at 0.7976 — a number that says nothing about an unseen disease.
`metrics.json` records it as `reference_auc` with a note not to use it. The
honest estimate is `lodo_auc`, 0.6383, which is what the site quotes.

**Traitar labels are not measurements.** The trait classifiers are trained on
Traitar calls, and Traitar itself infers phenotypes from gene content. So a
trait AUC says how well the embedding reproduces Traitar, not how well it
reproduces an experiment. BacDive values, where they exist, are the only
measured ones, and the cards label all three cases.

---

## Further reading

- [`deploy/WEB_CONFIG.md`](deploy/WEB_CONFIG.md) — the nginx config line by
  line, the systemd alternative, operational limits and failure modes.
- [`script/web_export/README.md`](script/web_export/README.md) — the build
  pipeline, and the two things in it that fail silently.
- [`tests/js/README.md`](tests/js/README.md) — what the browser tests assert,
  and the one place Python and JavaScript legitimately differ.
- [`web_design.md`](web_design.md) — design tokens, typography and the rules
  the pages follow.
