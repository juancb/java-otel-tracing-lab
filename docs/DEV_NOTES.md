# Dev notes (read me before editing in a Cowork session)

## Git workflow on this NTFS-mounted repo

The Cowork sandbox runs Linux but mounts your Windows NTFS workspace via a
bridge that **allows file create / rename but blocks unlink** in the
`.git/` directory (the mount inherits Windows ACLs from your user, the
sandbox process is a different uid).

That breaks every standard `git add` / `git commit` because git's normal
flow is *create lockfile, write data, rename lockfile to target, unlink any
stale lock*. The unlink step fails, so the next operation aborts with
"Another git process seems to be running."

### Workflow that works inside the sandbox

1. **Before any git operation**, rename any stale lock files (rename works
   even though unlink doesn't):

   ```bash
   for f in .git/*.lock .git/refs/heads/*.lock; do
     [ -f "$f" ] && mv "$f" "$f.gone.$(date +%s%N)" 2>/dev/null
   done
   ```

2. **Use a temp-path index** so git's working index lives somewhere we can
   delete files (`/tmp` in the sandbox):

   ```bash
   export GIT_INDEX_FILE=/tmp/git_index_$$
   git read-tree HEAD
   ```

3. **Stage files via plumbing** (skips the high-level `git add` lock dance):

   ```bash
   blob=$(git hash-object -w path/to/file)
   git update-index --add --cacheinfo 100644,$blob,path/to/file
   ```

4. **Commit via plumbing**:

   ```bash
   TREE=$(git write-tree)
   COMMIT=$(echo "msg" | git commit-tree $TREE -p $(git rev-parse HEAD))
   # rename any lock that commit-tree just left behind
   for f in .git/*.lock .git/refs/heads/*.lock; do
     [ -f "$f" ] && mv "$f" "$f.gone.$(date +%s%N)" 2>/dev/null
   done
   git update-ref HEAD $COMMIT
   ```

5. **Final cleanup pass on locks** (commit-tree / update-ref each create
   one):

   ```bash
   for f in .git/*.lock .git/refs/heads/*.lock; do
     [ -f "$f" ] && mv "$f" "$f.gone.$(date +%s%N)" 2>/dev/null
   done
   ```

This sequence is wrapped in `outputs/gitcommit.sh` (sandbox-only path).

### After working in the sandbox

The on-disk `.git/index` is *not* updated by the plumbing flow above — only
HEAD and the object store are. From a normal Windows PowerShell, `git
status` will show phantom diffs because the index is stale.

**To clear them**, in any normal shell after a sandbox session:

```bash
git reset HEAD          # reseats the on-disk index to HEAD
git status              # should now report clean
```

This loses no work. HEAD already has all the commits.

## File-write quirks

The sandbox `Write` tool (used to create / overwrite files) has had two
flavors of bug on this NTFS mount:

1. **Trailing null-byte padding** when overwriting a file with smaller
   content. Detect with `wc -c` vs file size; trim with
   `data.rstrip(b"\x00")` in Python.

2. **Truncation of the *last* part of a file** for some larger writes —
   the `Read` tool may show the full content while the on-disk file is
   truncated. Always verify large writes with `tail -5 <file>` and
   `wc -lc <file>`.

The reliable workaround: write large or critical files via
`cat > file <<'EOF' ... EOF` in bash — the kernel's standard write
syscalls don't trigger either bug.

## Running new services inside the lab

When adding a new docker-compose service:

1. Rebuild only that service: `docker compose up -d --build <name>`
2. If the service has a healthcheck, verify with `docker compose ps`
3. If it's behind a JVM agent, watch initial startup with
   `docker compose logs -f <name> | head -100`

## Where things live

- `/opt/otel/opentelemetry-javaagent.jar` - OTel agent in every JVM container
- `/opt/jmx-exporter/jmx_prometheus_javaagent.jar` - Prometheus JMX exporter (Stage B)
- `/etc/jmx-exporter/<role>.yaml` - per-role JMX scrape config
- Container service names in compose ARE the DNS names inside the lab
  network (`kafka`, `prometheus`, etc.)
