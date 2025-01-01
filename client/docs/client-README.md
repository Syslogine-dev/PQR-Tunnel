# OQS-SSH Client Setup

This repository contains the necessary scripts and configurations to set up a quantum-safe SSH client using the Open Quantum Safe (OQS) project.

---

## Overview

The OQS-SSH client enables quantum-safe SSH connections, ensuring security against potential quantum computer attacks. This project includes:

- **Setup Scripts**: Automates the installation and configuration of quantum-safe client tools.
- **Configuration Files**: Environment and dependency configurations for easy customization.

---

## Requirements

- **Operating System**: Linux (Debian-based distributions recommended)
- **Privileges**: Root access is required to run the scripts.
- **Dependencies**:
  - `build-essential`, `autoconf`, `automake`, `libtool`, `make`
  - `cmake`, `ninja-build`, `pkg-config`, `libssl-dev`

---

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/<your-repo-name>/oqs-ssh-client.git
   cd oqs-ssh-client
   ```

2. Ensure the `config` folder contains all necessary configuration files, such as:
   - `.env`
   - `install_dependencies.sh`

3. Run the setup script:
   ```bash
   ./client.sh
   ```

4. Follow the on-screen prompts and logs to ensure successful installation.

---

## Configuration

- Modify the `.env` file in the `config` folder to customize paths and repository URLs.

---

## Testing the Setup

After installation, test the client setup:

1. Connect to an OQS-SSH server:
   ```bash
   qssh -p 2222 user@<server-ip>
   ```

2. Verify file transfers:
   ```bash
   qscp <local-file> user@<server-ip>:<remote-path>
   ```

3. Check installed binaries:
   ```bash
   $INSTALL_PREFIX/bin/ssh -V
   ```

---

## Maintenance

- **Aliases**: Add the following aliases to your `~/.bashrc` for convenience:
  ```bash
  alias qssh='$INSTALL_PREFIX/bin/ssh'
  alias qscp='$INSTALL_PREFIX/bin/scp'
  ```

- **Logs**: Check the build logs or system logs for troubleshooting if issues arise.

---

## Contributing

Contributions are welcome! Please fork the repository and submit a pull request with your changes.

---

## License

This project is licensed under [LICENSE_NAME]. See the `LICENSE` file for details.