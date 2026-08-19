"""Pure parsing of `df` output.

Kept free of subprocess/IO so it can be exercised directly by table-driven
unit tests. The Django view is a thin wrapper: it runs `df`, hands the raw
stdout to :func:`parse_df`, and serializes the result to JSON.
"""

from __future__ import annotations

# Column order emitted by `df` (POSIX / GNU coreutils):
#   Filesystem  1K-blocks  Used  Available  Use%  Mounted on
# The mount point is always the trailing column and MAY contain spaces, so it
# is reconstructed by joining every remaining token. GNU df also wraps a very
# long device name onto its own line, with the numeric columns following on the
# next line — handled below via ``pending``.

_NUMERIC_COLUMNS = 5  # filesystem + blocks + used + available + use%  (before mount)


def parse_df(output: str) -> list[dict]:
    """Parse `df` stdout into a list of per-filesystem dicts.

    Each dict has keys: ``filesystem``, ``blocks``, ``used``, ``available``,
    ``use_percent`` (int, ``%`` stripped) and ``mounted_on``.

    Lines that cannot be parsed (blank, header, malformed, non-numeric where a
    number is expected) are skipped, so garbage input yields an empty list
    rather than raising.
    """
    rows: list[dict] = []
    pending: str | None = None  # a wrapped filesystem name awaiting its numbers

    for raw in output.splitlines():
        line = raw.strip()
        if not line:
            continue

        tokens = line.split()

        # Header row.
        if tokens[0] == "Filesystem":
            continue

        # Stitch a previously wrapped device name onto this line's numbers.
        if pending is not None:
            tokens = [pending] + tokens
            pending = None

        # A lone token is a wrapped filesystem name; carry it to the next line.
        if len(tokens) == 1:
            pending = tokens[0]
            continue

        if len(tokens) < _NUMERIC_COLUMNS + 1:
            # Not enough columns to be a real df row.
            continue

        filesystem = tokens[0]
        blocks, used, available, use_percent = tokens[1:5]
        mounted_on = " ".join(tokens[5:])

        try:
            entry = {
                "filesystem": filesystem,
                "blocks": int(blocks),
                "used": int(used),
                "available": int(available),
                "use_percent": int(use_percent.rstrip("%")),
                "mounted_on": mounted_on,
            }
        except ValueError:
            # Non-numeric value where a number was expected → not a df row.
            continue

        rows.append(entry)

    return rows
