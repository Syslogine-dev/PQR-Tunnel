# OQS-SSH Server Setup

This repository contains the necessary scripts and configurations to set up a quantum-safe OpenSSH server using the Open Quantum Safe (OQS) project.

---

## Overview

The OQS-SSH server provides quantum-safe cryptography for SSH connections, ensuring security against potential quantum computer attacks. This project includes:

- **Setup Scripts**: Automates the installation and configuration of quantum-safe tools.
- **Configuration Files**: Templates and environment files for customization.
- **Log Management**: Logrotate configuration to maintain system logs.

---

## Requirements

- **Operating System**: Linux (Debian-based distributions recommended)
- **Privileges**: Root access is required to run the scripts.
- **Dependencies**:
  - `build-essential`, `autoconf`, `automake`, `libtool`, `make`
  - `cmake`, `ninja-build`, `pkg-config`, `libssl-dev`
  - Additional dependencies for Kerberos, PAM, and SELinux

---

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/<your-repo-name>/oqs-ssh-server.git
   cd oqs-ssh-server
   ```

2. Ensure the `config` folder contains all necessary configuration files, such as:
   - `.env`
   - `sshd_config_template`
   - `logrotate_sshd_oqs`

3. Run the setup script:
   ```bash
   ./server.sh
   ```

4. Follow the on-screen prompts and logs to ensure successful installation.

---

## Configuration

- Modify the `.env` file in the `config` folder to customize paths, ports, and other settings.
- Update the `sshd_config_template` for specific SSH configuration needs.

---

## Testing the Setup

After installation, test the server:

1. Check the service status:
   ```bash
   systemctl status sshd_oqs
   ```

2. Test an SSH connection:
   ```bash
   ssh -p <port> -i ~/.ssh/id_falcon512 user@<server-ip>
   ```

3. Verify logs:
   ```bash
   journalctl -u sshd_oqs
   ```

---

## Maintenance

- Logs are managed via logrotate; ensure the configuration in `/etc/logrotate.d/sshd_oqs` is active.
- Use the `backup` folder in `/etc/ssh/` to restore older configurations if needed.

---

## Contributing

Contributions are welcome! Please fork the repository and submit a pull request with your changes.

---

## License

This project is licensed under [LICENSE_NAME]. See the `LICENSE` file for details.

