# Kunpeng Ubuntu Server Configuration

`kunpeng-setup.sh` provides an interactive menu for configuring Kunpeng Ubuntu
servers: enable the stable PPA, replace a 4K/64K kernel, and install or update
selected software.

## Prerequisites

- Ubuntu with Bash, APT, and an interactive terminal. The script checks for
  Ubuntu but does not enforce a release allowlist; the configured repositories
  must publish the required packages for your Ubuntu release and architecture.
- Native `arm64` package architecture for software installation and kernel
  replacement. Adding `arm64` as a foreign architecture on an `amd64` host does
  not satisfy this requirement or make ARM64 software runnable.
- Root access or working `sudo` for changes. The script requests privileges
  when needed; read-only inspection does not require root.
- Network access to all enabled APT repositories, including the public
  [Kunpeng stable PPA](https://launchpad.net/~huawei-kunpeng-ubuntu/+archive/ubuntu/kunpeng-stable)
  (`ppa:huawei-kunpeng-ubuntu/kunpeng-stable`). No Launchpad login or subscription
  is required.
- For kernel replacement: `update-grub`, an existing `/boot/grub/grub.cfg`,
  a standard GRUB default of `0`, and no third kernel image besides the running
  and target kernels. Ensure backups and console or out-of-band recovery access
  are available before changing kernels.

## Run

From the repository directory:

```bash
cd server-configuration-script
bash kunpeng-setup.sh
```

For read-only inspection:

```bash
bash kunpeng-setup.sh --preview
```

Preview reads the actual system state and cached APT metadata. It skips the
native ARM64 check, but still requires Ubuntu and an interactive terminal.
It blocks system-changing actions, including repository changes, index
refreshes, package installation/removal, and reboot. It is not a simulated
end-to-end installation or a test of package availability or boot success.
Use menu options **9** and **10** to inspect help and system information.

Enter a menu number, review the output, and answer confirmation prompts with
`y` or `Y` to proceed. Other answers decline the action. Press Enter when
prompted to return to the menu.

## Menu

| Option | Action |
| --- | --- |
| 1 | Import the Kunpeng stable PPA and refresh APT indexes; install `software-properties-common` if needed. |
| 2 | Switch from the running 4K kernel to 64K, or from 64K to 4K. |
| 3 | Install/update QEMU (`qemu-system-arm`). |
| 4 | Install/update libvirt (`libvirt-daemon-system`, `libvirt-clients`). |
| 5 | Install/update OpenSSL from the Kunpeng stable PPA. |
| 6 | Install/update `rasdaemon`. |
| 7 | Install/update `hikptool`. |
| 8 | Switch OpenSSL source: submenu **1** selects Kunpeng, **2** selects Ubuntu official, **0** returns. |
| 9 | Show help. |
| 10 | Show Ubuntu, architecture, running kernel/page size, and software status. |
| 0 | Exit. |

Import the stable PPA with option **1** before requesting Kunpeng package or
kernel changes. **Imported** means an enabled binary APT source exists; it
does not prove that the repository is accessible or its indexes are current.
Package status uses cached indexes, and source labels describe where a version
is available, not its historical installation source.

## Software and OpenSSL

Options **3-7** select the highest available version from the configured
Kunpeng stable PPA after refreshing indexes and install explicit
`package=version` specifications. They do not simply accept the global APT
candidate; a newer Ubuntu version does not override the selected PPA version
for that operation. The script rejects versions whose repository source is
ambiguous.

Before applying software changes, the script displays an APT simulation and
asks for confirmation. Plans that remove existing packages are refused.
Downgrades are explicitly warned about. Dependencies may be updated and
services restarted; the script does not configure services or user groups,
or perform automatic system-wide upgrades.

Option **8** selects OpenSSL and its required `libssl` packages from the chosen
repository, including Ubuntu official mirrors identified by Release Origin
`Ubuntu`. Switching may downgrade packages or affect services. It does not
create a persistent APT pin or change repository preferences, so later
upgrades may select another repository again.

The optional
[Kunpeng GCC PPA](https://launchpad.net/~huawei-kunpeng-ubuntu/+archive/ubuntu/kunpeng-gcc)
is separate. Adding it and managing its packages are manual tasks, not supported
by this script.

## Kernel Replacement and Recovery

Option **2** chooses the opposite page size using `linux-kunpeng-devel` for 4K
or `linux-kunpeng-devel-64k` for 64K. It resolves the versioned image from refreshed
stable PPA metadata and installs the target before attempting any removal.

The script verifies the target image, initramfs, configuration/page size,
modules, package ownership, and generated GRUB entry. It checks for additional
kernels and custom GRUB defaults, then displays a removal simulation and asks
for a separate confirmation. It refuses removal plans that remove the target
or non-kernel packages. Declining removal leaves the newly installed kernel
in place.

**Removing the running kernel can break further module loading until reboot,
and removes that kernel as a boot fallback.** Keep recovery access available
and review every proposed removal. These checks do not guarantee a successful
hardware boot.

After removal, the script updates GRUB and checks the target boot files again.
Only successful replacement leads to a separate reboot prompt. If reboot is
postponed, the old kernel remains running until you reboot manually. If any
step fails, review the output and repair the boot configuration before
rebooting; earlier package changes may remain.

## Repository Errors

APT refreshes use strict error handling: any enabled repository download error
stops the requested installation instead of falling back to stale indexes.
Fix repository URLs, publication status, network access, or HTTP 403 access
errors before retrying. The script does not select an alternate PPA or disable
signature verification. A failed PPA import may still leave its source enabled.
