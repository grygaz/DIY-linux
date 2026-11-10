# DIY Linux

**Kalba:** [English](README.md) | Lietuvių

Nedidelės Linux sistemos kūrimas iš šaltinių vienu Bash skriptu: [`diy-linux.sh`](diy-linux.sh). Skriptas atsisiunčia nustatytų versijų šaltinius, patikrina SHA-256 kontrolines sumas, sukuria kryžminio kompiliavimo įrankius (toolchain), šakninę failų sistemą ir paleidimo atvaizdus. Buildroot nenaudojamas.

Scenarijaus versija: **1.1.210** (`bash diy-linux.sh --version`). Versija rodoma paleidus scenarijų ir didinama su kiekvienu scenarijaus atnaujinimu.

Visi kūrimo receptai įtraukti į `diy-linux.sh`. Šį failą galima perkelti kitur ir paleisti atskirai. Ankstesni kūrimo ar bandymų failai nereikalingi. Atsisiuntimų, kompiliavimo ir toolchain katalogai sukuriami prireikus.

## Projekto principai

Projektas remiasi GNU laisvosios programinės įrangos idėja, kad žmonės turi galėti naudoti, nagrinėti, keisti ir dalytis savo programine įranga. Praktikoje kūrimo pasirinkimai ir receptai matomi pačiame skripte, šaltinių archyvų versijos užfiksuotos ir patikrinamos, o meniu bei `--plan` parodo apribojimus prieš ilgo kūrimo pradžią. Tikslas – padaryti sistemos kūrimą suprantamą ir keičiamą, o ne paslėpti jį uždarame įrankyje. Plačiau: [GNU paaiškinimas apie laisvąją programinę įrangą](https://www.gnu.org/philosophy/free-sw.en.html).

Dokumentacija yra šio darbo dalis: anglų ir lietuvių vadovuose turi sutapti komandos, pavojai ir žinomi apribojimai. Tai atliepia GNU požiūrį, kad dokumentacija būtina norint suprasti ir pritaikyti sistemą ([kodėl laisvai programinei įrangai reikia laisvos dokumentacijos](https://www.gnu.org/philosophy/free-doc.html)). Užfiksuotos versijos ir SHA-256 kontrolinės sumos patvirtina, kad atsisiuntimas sutampa su skripte nurodytu įvesties archyvu; jos savaime nepatvirtina autoriaus, negarantuoja bitais identiško kompiliavimo ir nepatvirtina visų komponentų licencijų. Prieš platindamas atvaizdą peržiūrėk komponentų licencijų pranešimus. [GNU kodavimo standartai](https://www.gnu.org/prep/standards/standards.html) pateikia naudingų bendrų gairių apie aiškią ir patikimą programinę įrangą; šis projektas neteigia esąs GNU paketas ar visiškai atitinkantis šiuos standartus. Jis nepriklausomas ir nėra oficialus GNU ar FSF projektas.

Kūrimo skriptui ir projekto dokumentacijai taikoma GNU bendroji viešoji licencija, 3 versija arba (pasirinktinai) bet kuri vėlesnė versija (`GPL-3.0-or-later`). Žr. [LICENSE](LICENSE). Atsisiųstiems komponentams galioja jų autorių licencijos.

## Greita pradžia

Paleisk skriptą įprasto naudotojo teisėmis x86_64 Linux kompiuteryje. Darbo katalogo kelias turi būti be tarpų.

```bash
bash diy-linux.sh --help
bash diy-linux.sh --plan
bash diy-linux.sh
```

Terminalo meniu leidžia kurti naują sistemą, tęsti nutrauktą kūrimą arba prižiūrėti esamą sistemą. Rodyklėmis judama, Enter atveria punktą, tarpo klavišas uždeda arba nuima varnelę. Pagalbos punktuose aprašyti pasirinkimai ir jų apribojimai. Trūkstamos kūrimo kompiuterio priklausomybės, įskaitant `dialog`, gali būti įdiegtos naudojant `sudo`.

Prieš kurdamas meniu pasirink naudotojo vardą ir įvesk slaptažodį. Numatytasis vardas yra `user`; naudotojas priklauso `sudo` grupei. Root paskyra užrakinta, kol nenustatytas jos slaptažodis. Paleistoje sistemoje administravimui naudok `sudo -i`.

## Sąsajos kalba

Pagal nutylėjimą kūrimo skriptas naudoja anglų kalbą, nepriklausomai nuo kompiuterio lokalės. Lietuvių kalbą įjungia `--LT`; šią vėliavą galima rašyti prieš kitą komandą arba po jos:

```bash
./diy-linux.sh
./diy-linux.sh --LT
./diy-linux.sh --LT --help
./diy-linux.sh --plan --LT
```

Šiuos pavyzdžius vykdyk saugyklos pagrindiniame kataloge. Kalba parenkama meniu, aprašymams, pagalbai, progresui ir skripto klaidų pranešimams. Kompiliatorių bei išorinių programų išvestis lieka jų naudojama kalba. Sugeneruoti sistemos pagalbiniai įrankiai naudoja konfigūravimo metu pasirinktą kalbą.

## Reikalavimai

- x86_64 Linux kūrimo kompiuteris su Bash 4.4 arba naujesniu ir interneto ryšiu.
- Daug laisvos vietos diske ir kelios valandos pirmajam kompiliavimui; poreikis priklauso nuo pasirinktų paketų.
- Pakankamai RAM ir swap GCC kompiliavimui. Prieš GCC etapus skriptas patikrina, ar yra bent 6 GiB laisvos RAM ir swap kartu; tai minimali patikra, o ne pakankamos atminties garantija.
- `sudo` kūrimo priklausomybėms diegti, chroot ir kai kuriems veiksmams su atvaizdais. Viso kūrimo nevykdyk root teisėmis.

Automatinis kūrimo kompiuterio priklausomybių diegimas palaiko `apt-get`, `pacman` ir `dnf`. Priklausomybes galima įdiegti atskirai:

```bash
bash diy-linux.sh --install-deps
```

Jei kūrimo kompiuterio paketus tvarkai pats, automatinį diegimą išjunk:

```bash
AUTO_INSTALL_DEPS=no bash diy-linux.sh --build
```

`--help` pateikia rankinio diegimo paketų sąrašą Debian / Ubuntu sistemoms ir papildomus reikalavimus atvaizdams, Fish bei darbalaukio profiliams. `--help` pateikia kūrimo kompiuterio priklausomybes pasirinktam profiliui. Kūrimo kompiuteryje naudojama paketų tvarkyklė nepriklauso nuo tos, kurią pasirenki naujai sistemai.

Jei GCC nutraukiamas su `Error 137`, patikrink laisvą atmintį ir kūrimo kompiuterio branduolio žurnalą. Skriptas gali paruošti laikiną swap:

```bash
bash diy-linux.sh --prepare-swap 8
```

Ši komanda darbo kataloge sukuria 8 GiB swap failą ir įjungia jį per `sudo`. `/etc/fstab` nekeičiamas. Esami ne swap failai neperrašomi; Btrfs atveju swap failą reikia paruošti atskirai. Komanda parodo, kaip vėliau išjungti swap.

## Kūrimo pasirinkimai

| Nustatymas | Pasirinkimai | Pastabos |
| --- | --- | --- |
| `TARGET_ARCH` | `x86_64`, `i686`, `aarch64` | AMD64 ir Intel64 naudoja tą pačią `x86_64` architektūrą. ARM64 receptas skirtas QEMU virt / UEFI, ne visoms ARM plokštėms. |
| `SHELL_CHOICE` | `bash`, `dash`, `zsh`, `fish`, `busybox` | BusyBox pasirinkimas naudoja ash. Zsh ir Fish atvejais `/bin/sh` yra dash. |
| `TOOLS_CHOICE` | `gnu`, `busybox` | Baziniai įrankiai pasirenkami atskirai nuo interaktyvaus apvalkalo. |
| `INIT_CHOICE` | `openrc`, `busybox`, `sysvinit`, `runit`, `dinit`, `s6`, `systemd` | OpenRC veikia su GNU arba BusyBox įrankiais; BusyBox profilyje vietinės ir nuosekliosios konsolės naudoja BusyBox `getty` ir `login`. Automatiniam prisijungimui vis tiek reikia GNU įrankių. SysVinit, runit, Dinit, s6 ir systemd reikia GNU įrankių. Dinit 0.22.1 yra beta versija; papildomai reikia šeimininko m4 ir tikslinės C++ bibliotekos. |
| `PACKAGE_MANAGER` | `none`, `apt`, `pacman` | APT apima dpkg. Abiem paketų tvarkyklių receptams reikia GNU įrankių. |
| `BOOT_CHOICE` | `bios`, `uefi`, `syslinux`, `lilo`, `refind`, `efistub`, `limine`, `systemd-boot`, `none` | `bios` ir `uefi` pasirenka GRUB. LILO yra senoji x86 BIOS paleidyklė, kurianti tik raw IMG; kūrimui sudo prijungia laikiną loop įrenginį. |
| `DESKTOP_CHOICE` | `none`, `mate`, `lxde`, `fluxbox` | MATE, LXDE ir Fluxbox Xorg profiliai kuriami iš nustatytų šaltinių archyvų; galimi deriniai priklauso nuo architektūros ir įrankių. |
| `WITH_GCC` | `yes`, `no` | Įtraukti kompiliatorių į galutinę sistemą. Kryžminis kompiliatorius kuriamas abiem atvejais. |
| `NETWORK` | `yes`, `no` | Įjungti DHCP tinklą. |
| `AUTOLOGIN` | `yes`, `no` | Pagal nutylėjimą `no`. Įjungus, vietinėje `tty1` konsolėje automatiškai atveriama `USER_NAME` paskyra neprašant slaptažodžio. Reikia GNU įrankių; nuosekliojo ryšio konsolė vis tiek prašo prisijungti. Fizinę prieigą turintis asmuo galės naudotis paskyra, o `sudo` ir toliau prašys slaptažodžio. |
| `DESKTOP_AUTOSTART` | `yes`, `no` | Pagal nutylėjimą `no`; palaiko pasirinktą darbalaukio profilį. Prisijungus vietinėje `tty1` konsolėje paleidžia darbalaukį. Kartu su `AUTOLOGIN=yes` galima praleisti ir konsolės slaptažodžio įvedimą. Uždarius darbalaukį grįžtama į terminalą; iki kito paleidimo darbalaukis automatiškai neįsijungs. |
| `PKG_NANO`, `PKG_WGET`, `PKG_PING`, `PKG_VIM`, `PKG_FDISK`, `PKG_GEANY`, `PKG_FIREFOX`, `PKG_PLUMA`, `PKG_CAJA`, `PKG_ENGRAMPA`, `PKG_MATE_CONTROL_CENTER`, `PKG_MATE_POWER_MANAGER` | `yes`, `no` | MATE/Xorg profilyje įtraukiamas vienintelis terminalas — xterm. Meniu filtruoja kitas programas pagal darbalaukį. MATE Control Center ir Power Manager veikia su systemd arba kita palaikoma init sistema. Ne systemd profiliuose kompiliuojamas elogind; visuose profiliuose kompiliuojamas Linux-PAM ir įjungiamas PAM sesijų sekimas, kad Polkit atpažintų prisijungusį vartotoją. Šioms parinktims būtini GNU įrankiai (BusyBox login nepalaikomas); jos gerokai pailgina kompiliavimą ir padidina ISO. Control Center taip pat reikia Rust ir Cargo librsvg bibliotekai. |
| `PKG_NGINX`, `PKG_PHP` | `yes`, `no` | Pasirenkami konsolinėje ir MATE sistemoje, nepriklausomai nuo darbalaukio. Nginx aptarnauja `/srv/www/html` per 80 prievadą. PHP kompiliuojamas su PHP-FPM, OpenSSL, zlib, XML ir SQLite palaikymu; jis naudoja vietinį Unix FastCGI lizdą. Pasirinkus PHP, įjungiamas ir Nginx. Paslaugos paruošiamos pasirinktai init sistemai. Pavyzdinis `index.php` tik patikrina PHP veikimą. TLS sertifikatus, ugniasienę ir konkrečioms programoms reikalingus PHP plėtinius sukonfigūruok atskirai. |

Neofetch ir pasisveikinimo pranešimas visada įtraukiami į naujas sistemas. Bash taip pat įtraukiamas Neofetch vykdyti, net pasirinkus kitą prisijungimo apvalkalą. `PKG_NEOFETCH=no` šio privalomo komponento neišjungia.

Kiti naudingi nustatymai: `SYSTEM_NAME`, `USER_NAME`, `WORK_DIR`, `JOBS`, `AUTO_INSTALL_DEPS` ir `COLOR`. Numatytasis `JOBS` yra 1; pradinio toolchain GCC etapai visada vykdomi viena kompiliavimo užduotimi, kad mažiau apkrautų atmintį. Spalvas išjungia `COLOR=never` arba `NO_COLOR=1`.

Tikslias nustatytas paketų versijas parodo:

```bash
bash diy-linux.sh --versions
```

Versijos automatiškai nesikeičia pasirodžius naujiems leidimams. Atnaujinant paketą reikia atnaujinti šaltinio URL ir kontrolinę sumą bei patikrinti kompiliavimo receptą.

### Kūrimas be meniu

Prieš kurdamas peržiūrėk konfigūraciją:

```bash
SHELL_CHOICE=bash TOOLS_CHOICE=gnu INIT_CHOICE=openrc \
  PACKAGE_MANAGER=none bash diy-linux.sh --plan
```

Naudojant `--build`, pateik SHA-512 crypt slaptažodžio maišą, kad įprastas naudotojas galėtų prisijungti. Šis pavyzdys slaptažodžio paprašo vietiniame terminale:

```bash
USER_PASSWORD_HASH="$(openssl passwd -6)" \
  USER_NAME=grygas SYSTEM_NAME=linmini \
  SHELL_CHOICE=bash TOOLS_CHOICE=gnu INIT_CHOICE=openrc \
  bash diy-linux.sh --build
```

Nepateikus slaptažodžio maišos paskyra lieka užrakinta. Maišos saugomos išsaugotuose kūrimo nustatymuose ir naujos sistemos `/etc/shadow`; šių failų neviešink ir nekelk į versijų valdymo sistemą.

Nedidelės BusyBox sistemos konfigūracija:

```bash
SHELL_CHOICE=busybox TOOLS_CHOICE=busybox INIT_CHOICE=busybox \
  bash diy-linux.sh --plan
```

Pasiruošęs pakeisk `--plan` į `--build` ir nustatyk naudotojo slaptažodį.

## Tęsti kūrimą arba kurti kitą sistemą

```bash
bash diy-linux.sh --resume   # Tęsti išsaugotą kūrimą
bash diy-linux.sh --new      # Konfigūruoti atskirą naują sistemą
bash diy-linux.sh --edit     # Pasirinkti esamą sistemą priežiūrai
bash diy-linux.sh --fresh    # Pradėti iš naujo, įskaitant toolchain kūrimą
```

Baigti etapai pažymimi žymų failuose. Tęsiamas kompiliavimas gali panaudoti iki nutraukimo sukurtus objektus. Suderinami baigti toolchain automatiškai naudojami pakartotinai, išskyrus atvejį, kai aiškiai pasirenkamas kūrimas nuo nulio.

Sėkmingai sukompiliuoti paketų etapai taip pat saugomi `WORK_DIR/artifacts/`. Naujas suderinamas profilis gali įdiegti šiuos failus jų nekompiliuodamas iš naujo; vien init ar paleidyklės pakeitimas įprastų userland programų talpyklos nepanaikina. Talpyklos raktas apima architektūrą, toolchain, prisegtų šaltinių kontrolines sumas, susijusius kūrimo receptus ir konkretaus etapo parinktis. Nesusiję scenarijaus ar dokumentacijos pakeitimai artefaktų nepanaikina. Šį katalogą ištrink tik tada, jei sąmoningai nori iš naujo kompiliuoti talpykloje esančius etapus.

Darbo kataloge sąmoningai paliekami šaltiniai, kompiliavimo objektai, žurnalai ir pakartotinai naudojami toolchain, kad po klaidos nereikėtų kartoti baigtų etapų. Galutiniame ISO yra paleidžiama sistema, bet nėra kompiliatoriaus kūrimo medžio, todėl ISO gali būti gerokai mažesnis už profilio katalogą. `WORK_DIR` nurodyk failų sistemoje, kurioje pakanka vietos; po klaidos naudok `--resume`, o pakeitus tik rootfs – `--repack`. Profilį išsaugok, kol gali prireikti tęsti kūrimą arba naudoti jo toolchain.

Bazinis live sistemos atvaizdas laikomas tik skaitymui skirtame `rootfs.squashfs`. Paleidimo metu initramfs ieško rašomo ext4 tomo, pažymėto `DIYDATA`, ir naudoja jį perdangos sluoksniui, todėl failų pakeitimai ir įdiegtos programos išlieka perkrovus sistemą. Jei tokio tomo nėra, naudojama RAM perdanga ir pakeitimai laikini. QEMU skirtas atskiras, numatytai 4 GiB talpos `persistence.ext4` failas sukuriamas šalia atvaizdų; jį automatiškai prijungia skripto pateikta QEMU komanda. Tai keičiamas svečio duomenų failas, todėl jis neįtrauktas į `SHA256SUMS`. Paleidimui iš USB laikmenos reikia joje sukurti ext4 skaidinį su žyma `DIYDATA`. Šis skaidinys nešifruotas. Initramfs yra tik ankstyvojo paleidimo įrankiai; darbalaukis ir įprastos programos lieka SquashFS.

Vienu metu nevykdyk dviejų kūrimų su tuo pačiu profiliu ar toolchain. Jei užraktas užimtas, patikrink nurodytą procesą ir tvarkingai sustabdyk ankstesnį kūrimą. Užrakto failo ištrynimas saugiai neatlaisvina veikiančio proceso laikomo užrakto.

Pradžioje progreso lentelėje išvardijami visi numatomi kūrimo etapai, įskaitant pasirinkto darbalaukio paketus. Laukiantys etapai rodo `0%`, baigti — `100%` ir savo trukmę minutėmis bei sekundėmis. Vykdymo metu keičiasi tik aktyvaus etapo eilutė. Jei sąrašas netelpa į terminalo aukštį, rodomas puslapis su vykdomu etapu; visa galutinė lentelė lieka terminalo istorijoje. Keičiant terminalo dydį lentelė perpiešiama, etapų būsenos išlieka. Aukštyn/žemyn slenka po vieną etapą, Page Up/Page Down arba kairėn/dešinėn keičia puslapį, Home/End perkelia į pradžią/pabaigą, F vėl seka vykdomą etapą. Kol lentelė atverta, klavišų aidas išjungtas; uždarant, įskaitant klaidą ar Ctrl+C, terminalo nustatymai atkuriami. Vykdomo etapo eilutėje juda veiklos indikatorius ir rodoma `--%`: make nepateikia patikimo viso etapo procento. Visa kompiliavimo išvestis saugoma profilio `build.log`; nepavykus rodomos klaidos. Antraštėje taip pat rodoma bendra šio paleidimo trukmė ir apytikslis likęs laikas. Sėkmingų etapų trukmės išsaugomos darbo katalogo `stage-times.tsv` ir naudojamos sutampančiai architektūrai, paketų/init/apvalkalo pasirinkimams bei kompiliavimo lygiagretumui. „Liko: renkami duomenys“ reiškia, kad istorijos dar nepakanka; `~20m + ?` įvertina žinomus etapus, o dalies trukmė dar nežinoma. Etapui viršijus ankstesnę trukmę, likęs laikas pažymimas nežinomu, o ne nuliu. Praleisti, nepavykę ir nutraukti etapai įvertinimo nekeičia. Prireikus rodomos valandos; `--resume` pradeda naują praėjusio laiko skaitiklį ir išsaugo istoriją.

## Kurti tik toolchain

```bash
bash diy-linux.sh --toolchain
TARGET_ARCH=aarch64 bash diy-linux.sh --toolchain
```

Sukuriami binutils, pradinis GCC, glibc ir galutinis GCC, nekuriant sistemos ar ISO. Pakartojus komandą tęsiami baigti toolchain etapai. Toolchain saugomi `WORK_DIR/toolchains/` ir turi savo `build.log` bei `sdk-env.sh`.

Sukūręs sistemą, papildomas programas jos rootfs gali kompiliuoti su to profilio SDK aplinka:

```bash
source /absolute/path/to/profile/sdk-env.sh
./configure --host=x86_64-diy-linux-gnu --prefix=/usr
make
make DESTDIR="$DIY_ROOT" install
```

Pavyzdžio kelius pakeisk savais. Naudok savo architektūrai tinkamą tikslinės sistemos identifikatorių (`--host`). Atskiro toolchain aplinka nukreipia į jo SDK sysroot, o sistemos profilio aplinka – į tos sistemos rootfs. Toolchain katalogų neperkelk: kompiliatoriaus konfigūracijoje naudojami jų pradiniai keliai.

## Prisijungti prie esamos sistemos ir ją keisti

```bash
bash diy-linux.sh --chroot
# Lygiavertė komanda:
bash diy-linux.sh --enter
```

Jei sukurta keletas sistemų, pasirink vieną meniu. Taip pat gali tiesiogiai nurodyti profilio katalogą:

```bash
bash diy-linux.sh --chroot /absolute/path/to/profile
```

Chroot viduje atlikti pakeitimai išlieka to profilio `rootfs`. Į kūrimo kompiuterio aplinką grįžtama komanda `exit`. Chroot naudoja kūrimo kompiuterio branduolį, procesoriaus informaciją ir veikimo laiką; naujai sukurtas rootfs neturi atskirai veikiančio branduolio. Kitai architektūrai paleisti reikia veikiančios `qemu-user` binfmt registracijos.

APT ir pacman yra pasirenkami įrankiai; automatiškai suderinamos distribucijos saugyklos neprijungiamos. Reikia savų suderinamų paketų ir saugyklų. Iš šaltinių sukurti baziniai failai neįregistruoti šių tvarkyklių paketų duomenų bazėse.

Jei įtrauktas vietinis GCC, kompiliuoti galima ir sistemos viduje. Papildomiems paketams gali reikėti antraštinių failų ir kūrimo priklausomybių, kurių minimaliame atvaizde nėra.

## Sukurti arba atnaujinti atvaizdus

Išėjęs iš chroot, pakeistą sistemą supakuok atskirai:

```bash
bash diy-linux.sh --iso
bash diy-linux.sh --img
bash diy-linux.sh --repack
```

Nenurodžius katalogo, šios komandos leidžia pasirinkti esamą sistemą. Profilį gali nurodyti tiesiogiai:

```bash
bash diy-linux.sh --iso /absolute/path/to/profile
```

`--iso` prašo sukurti ISO, `--img` – neapdorotą disko atvaizdą, o `--repack` naudoja profilyje nustatytą paleidimo formatą. Galimi formatai priklauso nuo paleidyklės. IMG gali turėti hibridinį ISO arba EFI FAT atvaizdą; jis nebūtinai yra įdiegta sistema su išliekančiais pakeitimais. LILO yra išimtis: jis kuria tik paleidžiamą DOS skaidinių lentelės ir ext2 failų sistemos disko atvaizdą (ISO nėra) ir prašo sudo tam atvaizdui prijungti per loop.

Skripto pateikta QEMU komanda automatiškai prijungia `persistence.ext4` ir įrašo nuosekliosios konsolės paleidimo išvestį į `images/qemu-boot.log` (failas perrašomas kiekvieną kartą paleidus QEMU). Žurnale matoma paleidyklės išvestis, jei ji perduodama per nuosekliąją konsolę, ir Linux branduolio / initramfs pranešimai; grafinio ekrano ir nebūtinai firmware išvesties jame nėra. Palik `persistence.ext4` šalia atvaizdų ir kiekvieną kartą paleisk sugeneruotą komandą. USB paleidimui sukurk tuščią ext4 skaidinį laikmenoje ir pažymėk jį `DIYDATA` naudodamas skaidinių tvarkyklę. Formatuojant skaidinys ištrinamas — rinkis tik tam skirtą tuščią skaidinį. Paleidimo metu live sistema jį aptiks ir naudos `upper`/`work` katalogus. Jei tomas neprijungtas arba jo nepavyksta prijungti, sistema pasileis su laikinais RAM pakeitimais.
