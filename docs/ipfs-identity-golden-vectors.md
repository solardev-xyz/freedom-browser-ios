# IPFS identity golden vectors

Captured from desktop Freedom (`/Users/florian/Git/freedom-dev/freedom-browser`,
`src/main/identity/{derivation,formats}.js`) on 2026-05-02. These are the
canonical expected outputs for the standard BIP-39 test mnemonics; the
iOS implementation must reproduce them byte-for-byte so a user with the
same seed phrase on desktop and iOS gets the **same IPFS PeerID** on both
platforms.

## Derivation chain

```
BIP-39 mnemonic
    │ mnemonicToSeedSync (PBKDF2-HMAC-SHA512, 2048 rounds, salt="mnemonic")
    ▼
64-byte seed
    │ SLIP-0010 (HMAC-SHA512, key="ed25519 seed")
    │ derive m/44'/73405'/0'/0'/0'  (all-hardened — required for Ed25519)
    ▼
32-byte Ed25519 private key + 32-byte chain code
    │ Ed25519 keygen
    ▼
32-byte private + 32-byte public
    │ libp2p PrivKey protobuf:
    │   field 1 (Type=Ed25519=1):  0x08 0x01
    │   field 2 (Data, 64 bytes):  0x12 0x40 + (priv 32B || pub 32B)
    │ → 68-byte protobuf, base64-encoded
    ▼
libp2p PrivKey (base64 string for kubo's config Identity.PrivKey)

For PeerID:
    libp2p PublicKey protobuf:
        field 1 (Type=Ed25519=1):  0x08 0x01
        field 2 (Data, 32 bytes):  0x12 0x20 + pub
    → 36-byte protobuf
    │ identity-multihash:  0x00 0x24 + above
    ▼ 38-byte multihash → Base58 → "12D3KooW…" PeerID
```

## SLIP-0010 path

```
m/44'/73405'/0'/0'/0'
```

`73405` is the custom unregistered coin type used by Freedom for IPFS
PeerIDs. `73404` is reserved for Radicle, `73406` for Swarm publisher
keys. All segments are hardened (suffix `'`) — required for SLIP-0010
Ed25519 (no public-only derivation).

## Vector 1 — 12-word standard test mnemonic

```
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about
```

| Layer | Value |
|---|---|
| BIP-39 seed (64B hex) | `5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4` |
| Ed25519 private key (32B hex) | `6d7c32198dff963096b93296acb383c9b4f2bd85a4e52c123bfee1e5cd00c749` |
| Ed25519 public key (32B hex) | `91237ad5959a25e025487deebe7bbae444e5ac2dfcd6fd10442d43dd87ef5647` |
| libp2p PrivKey (68B protobuf, hex) | `080112406d7c32198dff963096b93296acb383c9b4f2bd85a4e52c123bfee1e5cd00c74991237ad5959a25e025487deebe7bbae444e5ac2dfcd6fd10442d43dd87ef5647` |
| libp2p PrivKey (base64, kubo config form) | `CAESQG18MhmN/5Ywlrkylqyzg8m08r2FpOUsEjv+4eXNAMdJkSN61ZWaJeAlSH3uvnu65ETlrC381v0QRC1D3YfvVkc=` |
| **PeerID (base58)** | **`12D3KooWKavfSLKnBEoUdrcsZKHE2tCWxrPkND6psrNRyL8DgtYW`** |

## Vector 2 — 24-word standard test mnemonic

```
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art
```

| Layer | Value |
|---|---|
| BIP-39 seed (64B hex) | `408b285c123836004f4b8842c89324c1f01382450c0d439af345ba7fc49acf705489c6fc77dbd4e3dc1dd8cc6bc9f043db8ada1e243c4a0eafb290d399480840` |
| Ed25519 private key (32B hex) | `4212f8cf43eaa7070644e7b50a7e0d6ad7d02d8318890cb38d39935f66ba721a` |
| Ed25519 public key (32B hex) | `f7120786aaf4255b760002c2051de31306dc4f73bca521fa842df307908c0f13` |
| libp2p PrivKey (68B protobuf, hex) | `080112404212f8cf43eaa7070644e7b50a7e0d6ad7d02d8318890cb38d39935f66ba721af7120786aaf4255b760002c2051de31306dc4f73bca521fa842df307908c0f13` |
| libp2p PrivKey (base64, kubo config form) | `CAESQEIS+M9D6qcHBkTntQp+DWrX0C2DGIkMs405k19munIa9xIHhqr0JVt2AALCBR3jEwbcT3O8pSH6hC3zB5CMDxM=` |
| **PeerID (base58)** | **`12D3KooWSSppFRXRiW23YYh5zC8ZqSR2C3UgL2oJqhM5PjsAmxPk`** |

## Cross-checks already passing

- **BIP-39 seed values** match the canonical published BIP-39 spec test
  vectors for both 12-word and 24-word `abandon…` mnemonics. Confirms
  the underlying mnemonic-to-seed step is correct.
- **libp2p PrivKey hex shape**: bytes `0..3` are `08 01 12 40` (the
  protobuf header for `Type=Ed25519, Data=64B`); bytes `4..35` equal the
  Ed25519 private key; bytes `36..67` equal the Ed25519 public key.
  Confirms the protobuf layout matches `formats.js:60-65`.
- **PeerID prefix `12D3KooW`**: standard prefix for an identity-multihash
  base58 of an Ed25519 libp2p PublicKey protobuf. Confirms the
  multihash + base58 path matches `formats.js:74-87`.

## How the iOS implementation will use these

The Swift unit tests (`IpfsIdentityKeyTests.swift`,
`IpfsIdentityFormatsTests.swift`) will hard-code the values above as
expected outputs and assert byte/string equality against what our Swift
implementation produces for the same input mnemonic. Any divergence
between desktop and iOS gets caught at build time of the iOS test target.

For the SLIP-0010 derivation specifically, we'll also test against the
**published SLIP-0010 spec test vectors** (Test vector 1 and 2 from
<https://github.com/satoshilabs/slips/blob/master/slip-0010.md>) so the
implementation is independently verified at the standard layer too,
not only at the desktop-equivalence layer.

## Reproduction

To recompute these vectors at any time:

```bash
cd /path/to/freedom-browser
node -e "
const { deriveEd25519Key, getSeed, PATHS } = require('./src/main/identity/derivation');
const { createIpfsIdentity } = require('./src/main/identity/formats');
const m = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const k = deriveEd25519Key(getSeed(m), PATHS.IPFS);
console.log(createIpfsIdentity(k.privateKey, k.publicKey));
"
```
