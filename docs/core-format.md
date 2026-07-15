# Core Persistent Formats

Task 01 defines the persistent primitives used by later modules.

`StableId` is a UUIDv7-compatible 128-bit value. It is serialized as 16 bytes: `high` followed by `low`, each unsigned big-endian. Its canonical text form is lower-case UUID text. The first 48 bits carry logical UTC milliseconds, so a single generator remains ordered when the wall clock moves backwards or more than one sequence range is requested in a millisecond.

The binary envelope has a fixed 30-byte header followed by the payload. Every integer is unsigned big-endian.

| Offset | Length | Field |
|---:|---:|---|
| 0 | 4 | ASCII magic `SPND` |
| 4 | 2 | format version, currently `1` |
| 6 | 8 | stable schema ID |
| 14 | 4 | schema version |
| 18 | 4 | payload length |
| 22 | 8 | deterministic FNV-1a payload checksum |
| 30 | variable | payload |

The decoder requires the input length to exactly match the declared payload length and accepts a caller-selected payload maximum. The golden header bytes for schema ID `0x0102030405060708`, version `9`, and a three-byte payload begin with `53 50 4e 44 00 01 01 02 03 04 05 06 07 08 00 00 00 09 00 00 00 03`.

Clock durations use monotonic nanoseconds. Persisted timer wall time uses signed UTC milliseconds. Process-local keyed hashes are deliberately separate from deterministic content checksums and must never be written into persistent data.
