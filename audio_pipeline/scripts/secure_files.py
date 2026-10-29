import os
from pathlib import Path


def write_private_text(path, text):
    # Create the file as 0600 so the secret is never readable by others,
    # even briefly. chmod also tightens a file that already existed.
    path = Path(path)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        0o600,
    )

    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(text)

    path.chmod(0o600)
