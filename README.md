# BlackCube TradingView → Python Bridge → EA MT5

**Status: implementasi awal untuk pengujian akun demo saja. Belum tersertifikasi untuk penggunaan produksi dan tidak menjamin keuntungan.**

## Alur Kerja Sistem

1. Pine Script mendeteksi breakout pada candle yang telah ditutup, kemudian memanggil `alert()` dengan format JSON.
2. TradingView mengirimkan permintaan HTTPS POST ke `https://YOUR_HOST/tv/YOUR_LONG_RANDOM_SECRET`.
3. Python memvalidasi token rahasia, struktur data, timestamp, simbol, aksi, serta nilai SL dan TP.
4. Python menulis satu file instruksi JSON untuk setiap sinyal ke folder `Common\Files\BlackCube\inbox` secara atomik.
5. EA memeriksa folder tersebut, memvalidasi ulang risiko dan kondisi broker, menghitung ukuran lot berdasarkan ekuitas akun dan jarak Stop Loss, kemudian mengirimkan order.

EA menggunakan antrean file (*file queue*) alih-alih membuka server HTTP langsung di dalam MT5. `FILE_COMMON` merupakan area penyimpanan bersama yang dapat diakses oleh terminal MetaTrader sesuai mekanisme file MQL5.

## Batasan Penting Sebelum Digunakan pada Akun Live

- Implementasi ini merupakan versi dasar, bukan perangkat lunak trading produksi yang telah diaudit. Kompilasi melalui MetaEditor dan uji seluruh skenario menggunakan akun demo terlebih dahulu.
- Pembaca field JSON pada EA sengaja dibuat sederhana dan hanya cocok untuk format JSON datar yang digunakan dalam proyek ini. Sebelum digunakan pada lingkungan produksi, ganti dengan parser JSON yang teruji dan terpelihara.
- Pastikan fungsi `FileFindFirst` dan `FileMove` bekerja sesuai struktur folder pada versi MT5 yang digunakan. Pastikan Python menulis ke direktori Common Files MetaTrader yang benar.
- Nama simbol broker dapat berupa `XAUUSD.a`, `GOLD`, atau nama lainnya. Samakan konfigurasi simbol pada kedua sisi atau buat pemetaan simbol secara eksplisit.
- Pine Script menggunakan harga penutupan dan ATR dari feed TradingView. Feed broker MT5 serta harga eksekusi dapat berbeda. EA memvalidasi SL/TP terhadap harga pasar saat ini dan dapat menolak sinyal yang sudah tidak sesuai.
- Strategi contoh hanya digunakan untuk mendemonstrasikan alur pengiriman sinyal, bukan strategi trading yang telah terbukti memiliki keunggulan.
- Secret pada URL Python Bridge merupakan mekanisme autentikasi, tetapi dapat bocor melalui log atau konfigurasi. Gunakan HTTPS, secret acak yang panjang, pembatasan permintaan, firewall, penyamaran secret pada log, serta rotasi secret. Jangan pernah memasukkan kredensial broker ke dalam payload webhook.
- Pengiriman webhook dapat gagal. Pantau status webhook di TradingView dan siapkan notifikasi operasional serta prosedur pemulihan sebelum trading live.
- EA menyimpan ID sinyal yang telah diproses dalam file penanda. Pertahankan folder `processed_ids` dan siapkan mekanisme retensi atau pembersihan file. Jika terminal berhenti setelah broker menerima order tetapi sebelum ID tersimpan, rekonsiliasi dengan riwayat order MT5 mungkin tetap diperlukan.
- Persentase risiko merupakan estimasi berdasarkan `OrderCalcProfit`. Gap harga, slippage, komisi, dan kondisi eksekusi dapat membuat kerugian aktual berbeda.
- Sistem ini tidak menggunakan martingale, grid, penambahan posisi saat rugi (*averaging down*), atau transaksi pemulihan otomatis.

## 1. Instalasi Python

Gunakan Windows atau VPS Windows yang juga menjalankan MT5. Pasang Python versi 3.10 atau lebih baru.

```powershell
cd bridge
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Atur variabel lingkungan pada terminal yang sama sebelum menjalankan layanan:

```powershell
$env:BC_WEBHOOK_SECRET = "ganti-dengan-secret-acak-yang-panjang"
$env:BC_COMMON_FILES = "C:\Users\NAMA_USER_WINDOWS\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
$env:BC_ALLOWED_SYMBOLS = "XAUUSD"
$env:BC_MAX_AGE_SECONDS = "180"
$env:BC_MAX_SL_DISTANCE = "100"
$env:BC_MAX_TP_DISTANCE = "200"
python bridge.py
```

### Menentukan lokasi Common Files

Temukan lokasi folder yang digunakan MT5 melalui menu **File → Open Data Folder**, lalu periksa lokasi penyimpanan bersama terminal.

Direktori bersama biasanya berada di:

`%APPDATA%\MetaQuotes\Terminal\Common\Files`

Pastikan jalur yang digunakan Python benar-benar sama dengan jalur yang dibaca EA. Sebelum melakukan trading, uji dengan membuat file sederhana lalu pastikan file tersebut dapat dibaca oleh kedua komponen.

Server Flask bawaan hanya mengikat ke alamat localhost dan ditujukan untuk pengembangan lokal. Agar TradingView dapat mengirim webhook, gunakan reverse proxy HTTPS yang dikonfigurasi dengan benar pada port 443 atau layanan hosting HTTPS yang sesuai.

Webhook TradingView harus dapat dijangkau melalui internet dan menggunakan port 80 atau 443. Jangan mengekspos server pengembangan Flask secara langsung ke internet.

## 2. Konfigurasi TradingView

1. Buka chart XAUUSD dari feed yang ingin digunakan. Mulailah dengan timeframe M5.
2. Buka Pine Editor dan tempel kode dari `tradingview/blackcube_breakout.pine`.
3. Tambahkan indikator ke chart.
4. Buat alert dan pilih opsi **Any alert() function call**.
5. Isi webhook URL dengan alamat berikut:

   `https://YOUR_HOST/tv/YOUR_LONG_RANDOM_SECRET`

6. Jangan memasukkan kata sandi broker atau kredensial akun ke dalam pesan alert.
7. Periksa log alert TradingView untuk memastikan webhook berhasil dikirim.

Pine Script menghasilkan level SL dan TP berdasarkan ATR. Sesuaikan parameter strategi serta batas jarak SL/TP pada Python Bridge dengan karakteristik harga XAUUSD dari broker yang digunakan.

## 3. Instalasi EA MT5

1. Buka MT5, kemudian pilih **File → Open Data Folder**.
2. Salin `mt5/BlackCubeBridgeEA.mq5` ke folder `MQL5/Experts/`.
3. Buka file tersebut di MetaEditor dan lakukan kompilasi.
4. Pasang EA pada chart XAUUSD dan aktifkan **Algo Trading**.
5. Pertahankan pengaturan `InpAllowLiveAccount=false`. Validasi input EA membatasi persentase risiko per transaksi hingga maksimum 2%, dengan nilai awal 0,25%.
6. Pastikan Python dan MT5 menggunakan folder Common Files yang sama serta folder `BlackCube\inbox` tersedia.
7. Jalankan pengujian pada akun demo dan periksa tab **Experts** serta **Journal**.

## 4. Urutan Pengujian

- Pastikan endpoint `GET /health` memberikan respons `{"ok":true,...}`.
- Kirim alert pengujian dari TradingView dan pastikan satu file `.json` muncul di `BlackCube\inbox`.
- Periksa log EA untuk memastikan ID sinyal, aksi, lot yang dihitung, SL/TP, dan kode hasil transaksi tercatat.
- Kirim kembali alert dengan ID yang sama. Python seharusnya melaporkan duplikasi ketika file instruksi aslinya masih tersedia.
- Uji simbol yang tidak diizinkan, aksi yang tidak valid, timestamp kedaluwarsa, SL/TP yang tidak lengkap, dan secret yang salah.
- Uji kondisi spread tinggi, posisi yang sudah terbuka, Algo Trading yang dinonaktifkan, pasar tutup, margin tidak mencukupi, serta penolakan akibat batas minimum jarak SL/TP broker.
- Restart Python dan MT5 ketika terdapat instruksi dalam antrean. Setelah itu, cocokkan file yang tersisa dengan riwayat order dan transaksi broker.
- Lakukan backtest strategi secara terpisah dan lanjutkan dengan forward test di akun demo pada berbagai kondisi pasar.
- Pertimbangkan penggunaan akun live hanya setelah peninjauan kode, pencatatan log, kebijakan percobaan ulang, rekonsiliasi transaksi, serta batas risiko berhasil diuji.

## 5. Rekomendasi Pengaturan Risiko Awal

| Pengaturan | Nilai awal untuk akun demo |
|---|---:|
| Risiko per transaksi | 0,25% dari ekuitas |
| Maksimum posisi terbuka | 1 |
| Spread maksimum | Sesuaikan berdasarkan pengamatan spread broker |
| SL/TP | Contoh berbasis ATR; wajib divalidasi |
| Trading pada akun live | Dinonaktifkan |
| Martingale / grid | Dinonaktifkan |

Pengaturan ini merupakan nilai awal untuk pengujian teknis, bukan nasihat keuangan dan bukan jaminan bahwa sistem akan menghasilkan keuntungan atau terhindar dari kerugian.

---

## 📄 License

Proyek ini dirilis di bawah lisensi **MIT** — bebas digunakan, dimodifikasi, dan didistribusikan, dengan tetap menyertakan copyright notice. Lihat file [LICENSE](LICENSE) untuk teks lengkap.

**Disclaimer**: Software ini disediakan **"AS IS"**, tanpa jaminan apa pun. Trading forex/komoditas memiliki risiko kehilangan modal. Anda bertanggung jawab penuh atas penggunaan software ini. **Bukan nasihat finansial.**

---

## 💖 Support dan Donasi

Jika proyek ini bermanfaat, dukung pengembangan Black Cube ScannerFX melalui donasi sukarela.

<p align="center">
  <img src="qris-donasi.jpg" width="300" alt="QRIS Donasi Black Cube Code">
</p>

<p align="center">
  <em>Terima kasih atas dukungan Anda untuk pengembangan software independen.</em>
</p>

---
## 🎓 Tujuan Proyek

Project ini **edukasi** — untuk mempelajari:
- Cara TradingView alert() mengirim JSON
- Validasi webhook dengan secret + field + timestamp
- File queue pattern (producer-consumer)
- MQL5 EA: hitung lot, validasi SL/TP, eksekusi order
- Safety layer: dedupe, reject, retcode classifier
- Packaging Python jadi single .exe

**BUKAN** untuk trading live produksi. Lihat bagian "Batasan" di bawah.

## ⚠️ Keterbatasan untuk Edukasi

- Webhook `http://127.0.0.1` **hanya bisa diakses lokal** — untuk TradingView butuh **HTTPS** (Cloudflare Tunnel / VPS)
- Untuk **demo lokal**, kirim payload via `Invoke-RestMethod` (simulasi TradingView)
- TradingView **webhook** butuh akun **Premium** (Pro/Pro+)
- **Bukan nasihat finansial** — gunakan akun **DEMO** saja
## 📞 Kontak Developer

**BLACK CUBE CODE**

*Independent Developer — Expert Advisor and Algorithmic Trading*

- **Telegram:** [@blackcubecodeadmin](https://t.me/blackcubecodeadmin)
- **GitHub Repository:** [BlackCubeScannerFX](https://github.com/blackcubecode/BlackCubeScannerFX)
- **GitHub Issues:** [Laporkan Bug atau Ajukan Fitur](https://github.com/blackcubecode/BlackCubeScannerFX/issues)

---
