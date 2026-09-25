## WUD Authentication Configuration

The script requires access to the WUD API. To avoid storing credentials or local network addresses directly in the repository, the WUD connection settings should be stored in a separate `.wud-env` file in the user's home directory.

Create the file:

```bash
nano ~/.wud-env
```

Add the following configuration:

```bash
export WUD_URL="http://<WUD_HOST>:<WUD_PORT>/api/containers"
export WUD_USER="<WUD_USERNAME>"
export WUD_PASSWORD='<WUD_PASSWORD>'
```

Example:

```bash
export WUD_URL="http://192.168.1.100:3002/api/containers"
export WUD_USER="admin"
export WUD_PASSWORD='your_password'
```

The script automatically loads this file when it starts.

For security reasons, restrict access to the file:

```bash
chmod 600 ~/.wud-env
```

This ensures that only the file owner can read or modify the stored credentials.

The `.wud-env` file must **not** be committed to Git. Credentials, API tokens, passwords, and environment-specific IP addresses should always remain local.

If `.wud-env` is stored inside a Git repository, add it to `.gitignore`:

```gitignore
.wud-env
```

The script contains a default WUD URL, but values defined in `~/.wud-env` override the defaults automatically.
