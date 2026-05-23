# Nuketown Demo VM

A self-contained graphical NixOS VM that demonstrates Nuketown — one human
user, one agent (`ada`), real sudo approval via zenity. Buildable on any
Linux box that has Nix installed; no other dependencies.

## Running on Ubuntu (or any Linux with Nix)

### 1. Install Nix (skip if you already have it)

```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
```

Enable flakes:

```bash
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

### 2. (Optional but recommended) Get KVM access

Without KVM the VM still works but boots painfully slowly under TCG.

```bash
sudo apt install qemu-kvm        # gives you /dev/kvm
sudo usermod -aG kvm "$USER"     # log out and back in
```

You do **not** need to install QEMU itself — Nix will fetch it.

### 3. Boot the demo

```bash
nix run github:joshperry/nuketown#demo
```

That builds the qcow2 (first run takes a while — pulls XFCE + the rest of
the closure), copies it to `~/.local/state/nuketown-demo/demo.qcow2`,
and opens a QEMU window with the VM booting.

To start fresh next time, delete the scratch disk:

```bash
rm ~/.local/state/nuketown-demo/demo.qcow2
```

### Alternative: build the image and run it your own way

```bash
nix build github:joshperry/nuketown#demo-vm
# → result/nixos.qcow2 (read-only symlink into /nix/store)

cp --reflink=auto result/nixos.qcow2 /tmp/demo.qcow2
chmod u+w /tmp/demo.qcow2

# virt-manager → "Import existing disk image" → /tmp/demo.qcow2
# or:
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
  -drive file=/tmp/demo.qcow2,if=virtio,format=qcow2 \
  -netdev user,id=n,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n \
  -vga virtio -display gtk
```

## What you get

- XFCE desktop, auto-login as `human` (password `demo`)
- A `Welcome.txt` on the desktop with the demo walkthrough
- One agent: `ada`, uid 1100, home `/agents/ada`
- SSH on host port 2222 (`ssh human@localhost -p 2222`, password `demo`)

## The 60-second tour

Once the desktop loads, open `xfce4-terminal` and:

```bash
# Pop into a tmux split with ada on one side, you on the other.
portal-ada

# In the ada pane, ask for sudo. A zenity dialog appears on YOUR
# desktop asking whether to approve. Approve → ada gets root.
sudo whoami

# Or drop directly into ada's session:
sudo machinectl shell ada@

# ada has her own git identity:
git config --global user.email   # → ada@nuketown.demo
```

Reboot the VM and notice that `/agents/ada` is gone except for
`/agents/ada/projects` (the `persist` entry from her agent config).
The ephemeral-home story is conceptual in the demo image — there's no
separate btrfs subvolume to roll back to — but the persistence layout
matches the real `signi` setup.

## Layout

| File | Purpose |
| --- | --- |
| `demo/configuration.nix` | The NixOS system definition |
| `flake.nix` `nixosConfigurations.demo-vm` | Wires the module into a system |
| `flake.nix` `packages.x86_64-linux.demo-vm` | Builds the qcow2 |
| `flake.nix` `apps.x86_64-linux.demo` | Boots it under QEMU |
