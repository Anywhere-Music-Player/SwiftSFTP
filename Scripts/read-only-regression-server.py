"""Optional AsyncSSH fixture for SFTPReadOnlyRegressionTests; no system SSH changes."""
import argparse
import asyncio
import os
from pathlib import Path
import secrets
import shlex
import tempfile

import asyncssh


async def serve(host, port):
    with tempfile.TemporaryDirectory(prefix="swiftsftp-read-only-") as directory:
        root = Path(directory)
        (root / "one.bin").write_bytes(b"\0")
        (root / " spaced.bin ").write_bytes(bytes(range(99)))
        key = asyncssh.generate_private_key("ssh-ed25519")
        password = secrets.token_urlsafe(24)
        connections = set()

        class Server(asyncssh.SSHServer):
            def connection_made(self, connection):
                self.connection = connection
                connections.add(connection)

            def connection_lost(self, error):
                connections.discard(self.connection)

            def begin_auth(self, username):
                return True

            def password_auth_supported(self):
                return True

            def validate_password(self, username, supplied):
                return username == "regression" and secrets.compare_digest(password, supplied)

        class ReadOnly(asyncssh.SFTPServer):
            def __init__(self, channel):
                super().__init__(channel, chroot=os.fsencode(root))

            def open(self, path, flags, attrs):
                if flags & ~asyncssh.FXF_READ:
                    raise asyncssh.SFTPPermissionDenied("Read-only fixture")
                return super().open(path, flags, attrs)

            def denied(self, *args, **kwargs):
                raise asyncssh.SFTPPermissionDenied("Read-only fixture")

            write = remove = mkdir = rmdir = rename = posix_rename = symlink = link = setstat = fsetstat = lsetstat = open56 = copy_data = denied

        listener = await asyncssh.create_server(
            Server, host, port, server_host_keys=[key], sftp_factory=ReadOnly,
            sftp_version=3, public_key_auth=False, kbdint_auth=False,
            allow_pty=False, allow_scp=False, login_timeout=10,
        )
        values = dict(HOST=host, PORT=str(listener.get_port()), USERNAME="regression",
                      PASSWORD=password, HOST_KEY=key.export_public_key().decode().strip())
        for name, value in values.items():
            print("export SWIFTSFTP_REGRESSION_" + name + "=" + shlex.quote(value), flush=True)
        try:
            await asyncio.Event().wait()
        finally:
            listener.close()
            await listener.wait_closed()
            active = list(connections)
            for connection in active:
                connection.abort()
            for connection in active:
                await connection.wait_closed()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    try:
        asyncio.run(serve(args.host, args.port))
    except KeyboardInterrupt:
        pass
