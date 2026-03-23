# Workspace Environment

This directory provides a **self-contained workspace environment** for development and research on shared systems (HPC clusters, lab servers, and local Linux machines).

It is designed to:
- keep environments reproducible
- separate configuration, data, and tools
- work reliably across multiple platforms
- avoid polluting `$HOME` or system paths

---

## Directory Layout

```
 /cluster/work/projects/nn8104k/dsi014/envs/workspace
├── 📁 db
│   └── 📄 workspace_config.db
├── 📁 envbase
│   └── 📁 pytorch_311_cuda
│       ├── 📁 _bin
│       ├── 📁 bin
│       ├── 📁 share
│       ├── 📄 common.sh
│       ├── 📄 container.sif
│       └── 📄 img.sqfs
├── 📁 files
│   ├── 📁 condaenv
│   │   ├── 📄 env_cpu.yml
│   │   ├── 📄 env_cuda.yml
│   │   └── 📄 env_rocm.yml
│   └── 📄 gitconfig
├── 📁 platforms
│   ├── 📁 locallinux
│   │   ├── 📄 helper.sh
│   │   └── 📄 main.sh
│   ├── 📁 lumi
│   │   └── 📄 lumi.sh
│   ├── 📁 olivia
│   │   ├── 📄 helper.sh
│   │   └── 📄 main.sh
│   └── 📁 springfield
│       └── 📄 springfield.sh
├── 📁 programs
│   ├── 📁 linux
│   │   ├── 📄 azcopy
│   │   ├── 📄 code
│   │   ├── 📄 kubectl
│   │   ├── 📄 prog_alias.sh
│   │   ├── 📄 rclone
│   │   └── 📄 useful_cmd.sh
│   └── 📁 pymods
│       ├── 📁 fake
│       ├── 📁 manager
│       ├── 📁 pathremove
│       ├── 📁 ssh-agent
│       ├── 📁 tree
│       └── 📁 workspace
└── 📄 Readme.md
```

---

## Component Descriptions

### db/ — Workspace state and metadata

Stores persistent workspace state used by automation and management tools.

- workspace_config.db is an SQLite database
- Tracks repositories, experiments, branches, worktrees, and protection policies
- Acts as the source of truth for workspace operations
- Treated as state, not source code
- Should be modified via tooling rather than manual edits

---

### envbase/ — Built runtime environments (machine-specific)

Contains fully materialized runtime environments ready for execution.

Typical contents:
- unpacked environment layouts (_bin, bin, share)
- container images (container.sif, img.sqfs)
- helper scripts (common.sh)

Key properties:
- large and machine-specific
- intentionally ignored by Git
- rebuilt from specifications stored in files/

This directory contains environment results, not definitions.

---

### files/ — Configuration and environment specifications

Holds version-controlled configuration inputs.

- condaenv/
  - env_cpu.yml for CPU-only environments
  - env_cuda.yml for NVIDIA CUDA environments
  - env_rocm.yml for AMD ROCm environments
- gitconfig provides a shared Git configuration template

Everything here is portable, reviewable, and safe to commit.

---

### platforms/ — Platform-specific entrypoints

Contains scripts tailored to specific execution environments.

Each platform directory:
- sets environment variables and PATH
- activates the appropriate runtime environment
- adapts behavior to scheduler and filesystem constraints

Examples include local Linux machines and named HPC clusters.

This keeps platform logic isolated and explicit.

---

### programs/ — User-level tools and helpers

#### programs/linux/

Contains standalone binaries and shell utilities.

- azcopy, kubectl, rclone, code
- shell aliases and helper scripts
- added to PATH by platform entrypoints
- no system-wide installation required

#### programs/pymods/

Contains lightweight Python modules used by workspace tooling.

- installed via PYTHONPATH, not pip
- simple, inspectable, and editable
- used for workspace management, path handling, SSH agent setup, and utilities

---

## Design Principles

- explicit over implicit
- no global installs
- user-space only
- reproducible and portable
- conservative Unix and Git practices

The structure is designed to remain understandable and maintainable over time.

---

## Notes

- envbase/ and sensitive material are intentionally ignored by Git
- Python bytecode (.pyc, __pycache__) should never be committed
- The workspace can be copied, archived, or recreated on new systems

---

## Typical Usage

1. Clone the workspace repository
2. Build or unpack environments into envbase/
3. Select and run platform entry scripts
4. Manage repositories and experiments via workspace tools
5. Keep configuration, runtime artifacts, and code clearly separated
