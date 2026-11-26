#!/bin/sh
# Ames prefilter. Run inside the n8n container:  sh /data/prefilter.sh
# Full rebuild:                                 FULL=1 sh /data/prefilter.sh
#
# Reads the zips in /data (newest zip per year wins), keeps only rows from
# stores that were ever labeled AMES, writes small files to /data/raw.
# Zips are streamed with unzip -p, nothing big is unzipped to disk.
# Works with Data Hub CSV and JSON-lines files.
#
# Incremental: a zip is only processed when it is newer than its file in raw/.
# So a normal month only re-reads the new 2026 zip (a few minutes).
set -e
cd /data
mkdir -p raw
STORES=/data/ames_stores.txt

if [ "${FULL:-0}" = "1" ]; then
  echo "FULL rebuild: clearing raw and store list"
  rm -f raw/* "$STORES"
fi
touch "$STORES"

# 1. Newest zip per year (year = first 20xx in the file name).
ls -t *.zip > /tmp/all.txt
: > /tmp/use.txt
seen="|"
while IFS= read -r z; do
  y=$(echo "$z" | grep -oE '20[0-9]{2}' | head -1)
  case "$seen" in
    *"|$y|"*) echo "skip $z (older file for $y)" ;;
    *) seen="$seen$y|"; echo "$z" >> /tmp/use.txt ;;
  esac
done < /tmp/all.txt

# 2. Remove raw files that no longer belong to a used zip
#    (example: an old 2026 zip replaced by a newer download with another name).
for f in raw/*; do
  [ -e "$f" ] || continue
  b=$(basename "$f"); b=${b%.*}
  grep -qxF "$b.zip" /tmp/use.txt || { echo "remove old $f"; rm -f "$f"; }
done

# 3. Which zips need work: no raw file yet, or the zip is newer than its raw file.
: > /tmp/todo.txt
while IFS= read -r z; do
  b=$(basename "$z" .zip)
  out=""
  [ -e "raw/$b.csv" ] && out="raw/$b.csv"
  [ -e "raw/$b.json" ] && out="raw/$b.json"
  if [ -z "$out" ] || [ "$z" -nt "$out" ]; then
    echo "$z" >> /tmp/todo.txt; echo "process $z"
  else
    echo "keep    $z (raw file up to date)"
  fi
done < /tmp/use.txt

if [ ! -s /tmp/todo.txt ]; then
  echo "nothing new"
  du -sh raw
  exit 0
fi

# 4. Pass 1: store_no values ever labeled AMES in the zips to process.
#    Added to the saved list. Old rows have a blank city, so pass 2 uses store_no.
before=$(wc -l < "$STORES")
: > /tmp/new_stores.txt
while IFS= read -r z; do
  unzip -p "$z" | awk -F, '
    /^\{/ {
      if (tolower($0) ~ /"store_city":"ames/ && match($0, /"store_no":"[^"]*"/))
        print substr($0, RSTART + 12, RLENGTH - 13)
      next
    }
    tolower($0) ~ /,"?ames"?,/ { k = $3; gsub(/"/, "", k); print k }
  ' >> /tmp/new_stores.txt
done < /tmp/todo.txt
cat "$STORES" /tmp/new_stores.txt | sort -u > /tmp/stores.txt
mv /tmp/stores.txt "$STORES"
after=$(wc -l < "$STORES")
echo "ames store numbers: $after (new: $((after - before)))"
if [ "$before" -gt 0 ] && [ "$after" -gt "$before" ]; then
  echo "WARNING: new Ames store numbers found. Older years may miss their rows."
  echo "WARNING: run once with FULL=1 to rebuild all years."
fi

# 5. Pass 2: keep only rows from Ames stores. One output file per zip.
while IFS= read -r z; do
  b=$(basename "$z" .zip)
  rm -f "raw/$b.csv" "raw/$b.json"
  unzip -p "$z" | awk -F, -v out="raw/$b" '
    NR == FNR { s[$1]; next }
    /^\{/ {
      if (match($0, /"store_no":"[^"]*"/) && (substr($0, RSTART + 12, RLENGTH - 13) in s))
        print > (out ".json")
      next
    }
    { k = $3; gsub(/"/, "", k) }
    k == "store_no" { if (!h) { print > (out ".csv"); h = 1 } next }
    k in s { print > (out ".csv") }
  ' "$STORES" -
  echo "done $b"
done < /tmp/todo.txt

chmod -R a+rX raw
ls -la raw
du -sh raw