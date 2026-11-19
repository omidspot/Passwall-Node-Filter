# luci-app-pwfilter — Passwall Node Filter

**English** | [فارسی](#فارسی)

A LuCI app for OpenWrt that keeps your [Passwall](https://github.com/xiaorouji/openwrt-passwall) node list healthy. It pulls random batches of nodes from your subscription, tests them, and keeps only the good ones.

> ✅ **Tested** on a **Linksys EA8100** running **OpenWrt 23.05** with `luci-app-passwall` — it worked fine.

---

## English

### Features

- Shuffles the whole subscription and imports nodes in **random batches** (you choose the batch size).
- Each batch is imported into a **temporary group** (`<name>_tmp`), so healthy nodes from earlier batches are never wiped by a new import.
- Three test stages — a node that fails an enabled stage is deleted:
  1. **TCP ping** (direct, Passwall stopped, parallel)
  2. **YouTube test** through the node (one or more URLs, "any" or "all" must return HTTP 2xx)
  3. **Download speed test** (sequential, complete downloads only, minimum speed in KB/s, best of N attempts)
- Keeps at most **N healthy nodes**; when there are more, the **fastest** are kept.
- Repeats batches automatically until the target is reached, the subscription runs out, or you press **Stop**.
- Optionally re-tests existing nodes of the group at the start of each run.
- Optional scheduled run (every 1–24 hours) via cron. It schedules pwfilter only, never Passwall on/off.
- Live log inside LuCI, Run / Stop buttons.

### Requirements

- OpenWrt 23.05 with LuCI
- `luci-app-passwall` and a core (`xray-core` or `sing-box`)
- `curl`
- `tcping` or `nc` (optional — falls back to `curl` if `nc` lacks `-z`)
- A subscription that is a **URI list** (plain or base64). Clash YAML and SSD are not supported.

### Installation

**From LuCI (easiest)**

1. Download `luci-app-pwfilter_2.0.0-1_all.ipk` from the [Releases](../../releases) page.
2. Open **System → Software**.
3. Click **Upload Package…**, choose the `.ipk`, then **Upload** and **Install**.
4. Reload the LuCI page. The app appears under **Services → Passwall Node Filter**.

**From SSH**

```sh
scp luci-app-pwfilter_2.0.0-1_all.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
opkg install /tmp/luci-app-pwfilter_2.0.0-1_all.ipk
```

**Uninstall**

```sh
opkg remove luci-app-pwfilter
```

### Usage

1. Go to **Services → Passwall Node Filter**.
2. Enter your **Subscription URL**.
3. Set **batch size** (e.g. `30`) and **healthy target** (e.g. `10`).
4. Adjust the speed test (default: min `200` KB/s) and other options if you want.
5. Click **Save & Apply**, then **Run now**.
6. Watch progress in the **Live log** tab. Use **Stop** to cancel.

The kept nodes appear in Passwall under the group name you chose (default `pwfilter`).

### Settings

| Option | Meaning |
|---|---|
| Subscription URL | URI-list subscription (plain or base64) |
| Batch size | How many random configs are imported and tested per cycle |
| Healthy target | Stop when this many healthy nodes are in the group |
| Repeat until target | Keep taking new batches, or test only one batch |
| Also test existing nodes | Re-test nodes already in the group at the start of a run |
| Speed test / min KB/s | Enable the download test and set the minimum speed |
| Speed URL / timeout / attempts | File to download, max time, number of attempts (best result is used) |
| Node group name | Passwall group for kept nodes (letters, digits, `-`, `_`) |
| YouTube URLs / requirement | URLs to test and whether any or all must succeed |
| TCP / YouTube options | Timeouts, attempts, parallel jobs |
| Stop Passwall during the run | Tests use the direct internet (recommended) |
| Start Passwall again afterwards | Restart Passwall when finished |
| Automatic run | Run every N hours via cron |

### Command line

```sh
pwfilter bg     # run in background (log: /tmp/pwfilter.log)
pwfilter run    # run in foreground
pwfilter stop   # stop a running job
```

Config: `/etc/config/pwfilter`

### Notes & troubleshooting

- By default Passwall is **stopped during the run** so tests use the direct internet, then started again afterwards.
- Nothing imported? Check `/tmp/pwfilter/sub.log` (output of Passwall's `subscribe.lua`) and `/tmp/pwfilter.log`.
- Speed results depend on the test file and your line at that moment — adjust the minimum speed to your needs.

### Tested on

| Device | OpenWrt | Result |
|---|---|---|
| Linksys EA8100 | 23.05 | ✅ Works |

---

<div dir="rtl">

## فارسی

### معرفی

یک برنامه‌ی LuCI برای OpenWrt که لیست نودهای [Passwall](https://github.com/xiaorouji/openwrt-passwall) را سالم نگه می‌دارد. از سابسکریپشن شما به‌صورت تصادفی دسته‌دسته نود می‌گیرد، آن‌ها را تست می‌کند و فقط نودهای خوب را نگه می‌دارد.

> ✅ **تست‌شده** روی روتر **Linksys EA8100** با **OpenWrt 23.05** و `luci-app-passwall` — بدون مشکل کار کرد.

### امکانات

- کل سابسکریپشن را **بُر می‌زند** و نودها را در **دسته‌های تصادفی** وارد می‌کند (اندازه‌ی دسته با خودتان است).
- هر دسته در یک **گروه موقت** (`<name>_tmp`) وارد می‌شود؛ بنابراین نودهای سالمِ دسته‌های قبلی با ایمپورت جدید پاک نمی‌شوند.
- سه مرحله تست؛ نودی که در یک مرحله‌ی فعال رد شود حذف می‌شود:
  1. **TCP ping** (مستقیم، با Passwall خاموش، موازی)
  2. **تست YouTube** از داخل نود (یک یا چند آدرس، «حداقل یکی» یا «همه» باید HTTP 2xx بدهند)
  3. **تست سرعت دانلود** (پشت‌سرهم، فقط دانلود کامل حساب می‌شود، حداقل سرعت به KB/s، بهترین نتیجه از چند تلاش)
- حداکثر **N نود سالم** نگه می‌دارد؛ اگر بیشتر بود، **سریع‌ترین‌ها** می‌مانند.
- دسته‌ها را خودکار تکرار می‌کند تا به هدف برسد، سابسکریپشن تمام شود، یا شما **Stop** بزنید.
- امکان تست دوباره‌ی نودهای موجود گروه در ابتدای هر اجرا.
- اجرای زمان‌بندی‌شده (هر ۱ تا ۲۴ ساعت) با cron. فقط pwfilter زمان‌بندی می‌شود، نه روشن/خاموش شدن Passwall.
- لاگ زنده داخل LuCI و دکمه‌های Run / Stop.

### پیش‌نیازها

- OpenWrt 23.05 همراه LuCI
- `luci-app-passwall` و یک هسته (`xray-core` یا `sing-box`)
- `curl`
- `tcping` یا `nc` (اختیاری — اگر `nc` گزینه‌ی `-z` نداشت از `curl` استفاده می‌شود)
- سابسکریپشن از نوع **لیست URI** (ساده یا base64). Clash YAML و SSD پشتیبانی نمی‌شود.

### نصب

**از طریق LuCI (ساده‌ترین روش)**

1. فایل `luci-app-pwfilter_2.0.0-1_all.ipk` را از صفحه‌ی [Releases](../../releases) دانلود کنید.
2. به **System ← Software** بروید.
3. روی **Upload Package…** بزنید، فایل `.ipk` را انتخاب کنید، سپس **Upload** و **Install**.
4. صفحه‌ی LuCI را رفرش کنید. برنامه در **Services ← Passwall Node Filter** ظاهر می‌شود.

**از طریق SSH**

```sh
scp luci-app-pwfilter_2.0.0-1_all.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
opkg install /tmp/luci-app-pwfilter_2.0.0-1_all.ipk
```

**حذف**

```sh
opkg remove luci-app-pwfilter
```

### نحوه‌ی استفاده

1. به **Services ← Passwall Node Filter** بروید.
2. **Subscription URL** را وارد کنید.
3. **اندازه‌ی دسته** (مثلاً `30`) و **تعداد نود سالم هدف** (مثلاً `10`) را تنظیم کنید.
4. تست سرعت (پیش‌فرض: حداقل `200` KB/s) و بقیه‌ی گزینه‌ها را در صورت نیاز تغییر دهید.
5. روی **Save & Apply** و بعد **Run now** بزنید.
6. پیشرفت را در تب **Live log** ببینید. برای لغو، **Stop** را بزنید.

نودهای نگه‌داشته‌شده در Passwall زیر نام گروهی که انتخاب کرده‌اید (پیش‌فرض `pwfilter`) دیده می‌شوند.

### تنظیمات

| گزینه | توضیح |
|---|---|
| Subscription URL | سابسکریپشن از نوع لیست URI (ساده یا base64) |
| Batch size | تعداد کانفیگ تصادفی که در هر چرخه وارد و تست می‌شود |
| Healthy target | وقتی این تعداد نود سالم در گروه باشد متوقف می‌شود |
| Repeat until target | ادامه‌ی گرفتن دسته‌های جدید، یا فقط تست یک دسته |
| Also test existing nodes | تست دوباره‌ی نودهای موجود گروه در ابتدای اجرا |
| Speed test / min KB/s | فعال‌سازی تست دانلود و حداقل سرعت |
| Speed URL / timeout / attempts | فایل دانلود، حداکثر زمان، تعداد تلاش (بهترین نتیجه استفاده می‌شود) |
| Node group name | گروه Passwall برای نودهای نگه‌داشته‌شده (حروف، عدد، `-` و `_`) |
| YouTube URLs / requirement | آدرس‌های تست و اینکه حداقل یکی یا همه باید موفق باشند |
| TCP / YouTube options | timeout، تعداد تلاش، تعداد کار موازی |
| Stop Passwall during the run | تست‌ها با اینترنت مستقیم انجام شود (پیشنهادی) |
| Start Passwall again afterwards | پس از پایان Passwall دوباره راه‌اندازی شود |
| Automatic run | اجرای خودکار هر N ساعت با cron |

### خط فرمان

```sh
pwfilter bg     # اجرا در پس‌زمینه (لاگ: /tmp/pwfilter.log)
pwfilter run    # اجرا در پیش‌زمینه
pwfilter stop   # توقف کار در حال اجرا
```

فایل تنظیمات: `/etc/config/pwfilter`

### نکات و عیب‌یابی

- به‌طور پیش‌فرض Passwall **در طول اجرا خاموش** می‌شود تا تست‌ها با اینترنت مستقیم انجام شوند، و بعد از پایان دوباره روشن می‌شود.
- هیچ نودی وارد نشد؟ فایل‌های `/tmp/pwfilter/sub.log` (خروجی `subscribe.lua` پاس‌وال) و `/tmp/pwfilter.log` را ببینید.
- نتیجه‌ی سرعت به فایل تست و وضعیت خط در همان لحظه بستگی دارد — حداقل سرعت را مطابق نیاز خودتان تنظیم کنید.

### تست‌شده روی

| دستگاه | OpenWrt | نتیجه |
|---|---|---|
| Linksys EA8100 | 23.05 | ✅ کار می‌کند |

</div>
