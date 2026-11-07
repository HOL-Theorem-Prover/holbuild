#!/bin/sh
# provers.sh: installs the automated provers HOL projects call into /opt/provers/bin, for this machine's architecture
# (arm64 or amd64): E, Vampire and Zipperposition for the hammer, z3 and cvc5 for HolSmt. Each is a pinned release of
# its project (E and Zipperposition as Isabelle's prebuilt components), checked against its archive's SHA-256.
set -eu

arch=$(dpkg --print-architecture)
case $arch in
  arm64)
    e=arm64 vampire=ARM64 z3=arm64-glibc-2.34 cvc5=arm64
    vampire_sha=7abc39224fdf41bdb2c241f8b180a80b7c1a4bce1e46dc79df02cfea2798ad5c
    z3_sha=956afce4dae2d8d59071f7b2fcd052912ca50a9efb905e646a091befac0ad999
    cvc5_sha=21bd93916b3214ba64538cbd82bb2f6650ab441c5781f6c83afd3707d78d79da ;;
  amd64)
    e=x86_64 vampire=X64 z3=x64-glibc-2.35 cvc5=x86_64
    vampire_sha=495828dc76cb17a27080d62dedce755e46de96f47f06f5f0ad4be9cdaf6f968f
    z3_sha=642f569aa40ef3d1727ad3cdb8c7f5145ed1a58e0b49e89b46878326fe111b61
    cvc5_sha=1060daaf507edef9d0a68e399cfc0e9038150bccb9e2d34d081d50a7687544d2 ;;
  *) echo "provers.sh: no provers for the architecture $arch (arm64 or amd64)" >&2; exit 1 ;;
esac

bin=/opt/provers/bin
mkdir -p "$bin"
work=$(mktemp -d)
cd "$work"

# fetch FILE URL SHA256: downloads URL as FILE and checks its SHA-256.
fetch() {
  curl -fsSL -o "$1" "$2"
  echo "$3  $1" | sha256sum -c --quiet -
}

fetch e.tar.gz https://isabelle.in.tum.de/components/e-3.2.tar.gz \
  adc35617f10c74ab8d3d13aacac57a68b9ce2c61b6da9ced5e2e370469b77305
tar xzf e.tar.gz "e-3.2/$e-linux/eprover"
install -m 755 "e-3.2/$e-linux/eprover" "$bin/eprover"

fetch vampire.zip "https://github.com/vprover/vampire/releases/download/v5.1.0/vampire-Linux-$vampire.zip" "$vampire_sha"
unzip -q vampire.zip vampire
install -m 755 vampire "$bin/vampire"

# Zipperposition links libgmp.so.10, which the image has from libgmp-dev.
fetch zipperposition.tar.gz https://isabelle.in.tum.de/components/zipperposition-2.1-2.tar.gz \
  98adec94cf87507b6762eca7d9618fcee7d94496c09368c146001c59174874b8
tar xzf zipperposition.tar.gz "zipperposition-2.1-2/$e-linux/zipperposition"
install -m 755 "zipperposition-2.1-2/$e-linux/zipperposition" "$bin/zipperposition"

fetch z3.zip "https://github.com/Z3Prover/z3/releases/download/z3-4.13.2/z3-4.13.2-$z3.zip" "$z3_sha"
unzip -q z3.zip "z3-4.13.2-$z3/bin/z3"
install -m 755 "z3-4.13.2-$z3/bin/z3" "$bin/z3"

fetch cvc5.zip "https://github.com/cvc5/cvc5/releases/download/cvc5-1.3.2/cvc5-Linux-$cvc5-static.zip" "$cvc5_sha"
unzip -q cvc5.zip "cvc5-Linux-$cvc5-static/bin/cvc5"
install -m 755 "cvc5-Linux-$cvc5-static/bin/cvc5" "$bin/cvc5"

cd /
rm -rf "$work"
