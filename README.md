# hermes-live — Hermes ni GitHub Actions da 24/7 ushlab turuvchi o'zini-ko'chiruvchi runner

## Bu nima

GitHub-hosted runner bitta job'ni **maksimum 6 soat** (360 daqiqa) ishga tushira oladi.
Bu rig har **~5 soat 15 daqiqada** (315 daqiqa, cap'dan oldin) jonli holatni
**shaxsiy** repoga saqlab, keyin o'zining "vorisi" job'ini ishga tushiradi va o'zini o'chiradi.
Natija: Virtual mashina har siklda yangilanadi, agent eskirishni boshdan kechirmaydi.

```
┌─────────────────────────────┐        state.tar.gz        ┌──────────────────┐
│ GitHub Actions (public repo)│  ────────────────────────► │ PRIVATE repo     │
│  scripts/runner.sh          │                            │  state.tar.gz    │
│  - brain'ni tiklaydi        │  ◄──────────────────────── │  (config, .env,  │
│  - gateway'ni ishga tushiradi│                           │   memories, db)  │
│  - 315 daqiqadan keyin:     │                            └──────────────────┘
│    snapshot → dispatch → exit│
└─────────────────────────────┘
        ▲                                        │
        └──────── watchdog (har 20 daqiqada) ─────┘
              agar jonli run yo'q yoki eskirgan bo'lsa → qayta dispatch
```

## Fayllar

| Fayl | Vazifa |
|---|---|
| `scripts/runner.sh` | Job ichidagi asosiy skript (tiklash → ishga tushirish → snapshot → dispatch) |
| `scripts/brain.sh` | `pack` / `restore` / `fetch` / `snapshot` — profillingizni tar bilan siqish/yuklash |
| `.github/workflows/run.yml` | Asosiy (jonli) workflow |
| `.github/workflows/watchdog.yml` | Nazoratchi: jonli run o'lib qolsa qayta ishga tushiradi |
| `setup.sh` | Bir martalik so'zlama (repolar, secret, birinchi snapshot) — **siz** ishga tushirasiz |

## O'rnatish

```bash
bash setup.sh     # owner, repo nomlari, PAT so'raydi; qolganini avtomatik qiladi
```

Keyin: repo Actions sahifasida **hermes-live** ni qo'lda bir marta ishga tushiring
(yoki watchdog'ga ~20 daqiqa vaqt berib kuting).

## Qoidalar-chegaralar (o'qib chiqing)

- **Actions CI/CD uchun mo'ljallangan.** Doimiy agent-ishchi "production workload" deb
  hisoblanadi va GitHub ToS ga chetda bo'lishi mumkin — berilgan repolar yoki hisob
  bloklanashi mumkin. Bu dizayn hech qanday yashirish muloyil, shaffof ishlaydi;
  chunki tahdid bo'lsa, xuddi shu `brain.sh restore` bilan istalgan VM'ga 1 daqiqada ko'chishingiz mumkin.
- **PATni hech kimga bermang, hech qayerga commit qilmang.** U faqat
  `BRAIN_TOKEN` secret'i (shifrlangan) ichida yotadi; kodda `.env`/token yo'q.
- **`hermes-brain` reposi doimo PRIVATE bo'lsin!** Unda `.env`, kalitlar va
  Siz bilan yozishgan tarix turibdi. Taqdirgan holda ham kalitlar umuman boshqa
  repoda bo'lmasin.
- **Fine-grained PAT tavsiya:** faqat shu 2 repoga, `Contents: Read/Write` +
  `Actions: Read/Write`, muddatsiz. Umumiy (classic) PAT muammoli.
- Har siklda kichik bir uyali-fasnlar (iki VM'ning Telegram'da kesishuvi) mumkin —
  adapter odatda 409'dan keyin o'zini tuzatadi.
- Snapshot har 600 daqiqada + sikl oxirida. Agent o'lib qolsa, ko'pi bilan
  ~10 daqiqalik holat yo'qoladi.

## Muammo holatlarda

- **Gateway start berilmayapti** → `RUN_LOG` (/tmp/hermes-gateway.log) ni Actions log'idan o'qing.
- **Hech qanday run ishlamayapti** → `hermes-live` ni qo'lda dispatch qiling; repolarni tekshiring.
- **GitHub bloklaganda** → Oracle Cloud **Always Free** (Ampere ARM 4 yadro / 24 GB,
  abadiy bepul) ga o'ting: `brain.sh restore` orqali holatni tiklang, gateway'ni
  `tmux`/`systemd` ostida ishga tushiring. Dizayn shu erda ham to'liq ishlaydi.

## Xavfsizlik yog'i

- Public repo: faqat workflow + skriptlar (maxfiy narsa yo'q).
- Private repo: holat (config, .env, db, tarix).
- Shifrlash hohishi bo'lsa: `tar` o'rniga `openssl enc -aes-265-cbc` bilan şifrlab,
  parolni ham `BRAIN_TOKEN` kabi secret qiling (`brain.sh` ni shunga moslashtirib qo'yaman).
