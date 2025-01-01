# PQR-Tunnel: Quantum-Safe SSH Tunnel

PQR-Tunnel enables quantum-safe communication between a client and a server using Open Quantum Safe (OQS) technologies. It is designed to provide enhanced security against potential quantum computer threats while maintaining compatibility with existing systems.

---

## Features

- **Quantum-Safe Algorithms**: Supports post-quantum cryptographic algorithms for key exchange and authentication.
- **Modular Architecture**: Configurations for both the client and server are modular and easily adjustable.
- **Easy Setup**: Scripts for automating installation, configuration, and service management.
- **Compatibility**: Works alongside classic RSA-based SSH for backward compatibility.

---

## Folder Structure

```plaintext
PQR-Tunnel/
├── client/
│   ├── config/
│   │   ├── .env
│   │   └── install_dependencies.sh
│   ├── client.sh
│   └── README.md
├── server/
│   ├── config/
│   │   ├── .env
│   │   ├── install_dependencies.sh
│   │   ├── sshd_config_template
│   │   ├── logrotate_sshd_oqs
│   │   └── sshd_oqs.service.template
│   ├── server.sh
│   └── README.md
└── shared/
    ├── README.md
    └── [shared configuration files]
```

---

## Quick Start Guide

### 1. Clone the Repository

```bash
git clone https://github.com/<your-repo-name>/PQR-Tunnel.git
cd PQR-Tunnel
```

---

### 2. Setup the Server

1. Navigate to the server directory:
   ```bash
   cd server
   ```

2. Ensure the `config/` folder contains all necessary files:
   - `.env`
   - `install_dependencies.sh`
   - `sshd_config_template`
   - `logrotate_sshd_oqs`
   - `sshd_oqs.service.template`

3. Run the server setup script:
   ```bash
   ./server.sh
   ```

4. Follow the on-screen instructions to complete the setup.

---

### 3. Setup the Client

1. Navigate to the client directory:
   ```bash
   cd client
   ```

2. Ensure the `config/` folder contains all necessary files:
   - `.env`
   - `install_dependencies.sh`

3. Run the client setup script:
   ```bash
   ./client.sh
   ```

4. Test the connection to the server:
   ```bash
   qssh -p <port> user@<server-ip>
   ```

---

## Testing the Setup

- **Check Service Status** (Server):
  ```bash
  systemctl status sshd_oqs
  ```

- **Test SSH Connection** (Client):
  ```bash
  ssh -p <port> -i ~/.ssh/id_falcon512 user@<server-ip>
  ```

- **File Transfers**:
  ```bash
  qscp <local-file> user@<server-ip>:<remote-path>
  ```

---

## Contributing

Contributions are welcome! Please fork the repository and submit a pull request with your improvements or fixes.

---

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
