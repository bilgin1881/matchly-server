# MATCHLY bulut sunucusu — 0.6.0

Bu klasör Flutter uygulaması değildir. Yalnızca maç programını sağlayan sunucuyu
Render üzerinde çalıştırır. Telefonda son yüklenen programdan oluşturulan
bildirimler çalışmaya devam eder. Veri sağlayıcısının tarih erişimi ve kotası
aynı kalır; sunucuyu taşımak tam haftalık program erişimi sağlamaz.

## 1. GitHub deposu

1. https://github.com/new adresinde `matchly-server` adlı **Private** depo oluştur.
2. README ekleme seçeneğini aç. Depoyu oluşturduktan sonra **Add file → Upload files** seç.
3. Bu klasörün `server.dart`, `server_test.dart`, `cloud_test.dart`, `Dockerfile`,
   `render.yaml` ve `README_TR.md` dosyalarını deponun köküne yükle.
4. **Commit changes** ile kaydet. API anahtarını hiçbir dosyaya yazma.

ZIP dosyasının kendisini GitHub'a yükleme. Render'ın göreceği depo kökünde
`Dockerfile` ve `server.dart` olmalı. Ek Flutter dosyaları gerekmez.

## 2. Render'da oluşturma

1. https://dashboard.render.com adresinde GitHub hesabınla giriş yap.
2. **New → Blueprint** seç ve yalnızca `matchly-server` deposuna erişim ver.
3. `render.yaml` dosyasındaki ayarları kullan: Docker, Frankfurt, Free, `/health`.
4. Sorulan **MATCHLY_FOOTBALL_KEY** alanına mevcut API-Football anahtarını gir.
   Anahtar Render'ın sunucu ortam ayarıdır. Sohbete veya Flutter'a ekleme.
5. Oluşturmayı başlat. Erişim için **MATCHLY_CLIENT_TOKEN** otomatik oluşturulur.
   Değeri Render'ın **Environment** bölümünden alıp bilgisayarında kullanacaksın.
6. Docker önce sunucu ve erişim testlerini çalıştırır, sonra programı derler.
   Başarılı olduğunda **Live** durumunu ve `https://....onrender.com` adresini kontrol et.
7. Adresin sonuna `/health` ekle. `status: ok` sunucunun çalıştığını gösterir;
   API hesabına erişimin doğrulandığı anlamına gelmez.

Blueprint yerine **New → Web Service** kullanırsan: aynı depoyu seç; Language
Docker, Free, Frankfurt, Dockerfile `./Dockerfile`, health `/health`.
Environment'a `MATCHLY_PUBLIC_SERVER=true`, `MATCHLY_FOOTBALL_KEY` ve en az
32 karakterlik rastgele `MATCHLY_CLIENT_TOKEN` ekle. Render'ın otomatik
`RENDER_EXTERNAL_HOSTNAME` ve `PORT` değerlerini değiştirme.

## 3. Telefon uygulamasını bağlama

Güncel Flutter paketindeki `lib/main.dart`, `lib/notification_service.dart` ve
`pubspec.yaml` dosyalarını mevcut projene kopyala. `start-cloud.ps1` dosyasını
proje köküne koy. Android/Gradle dosyalarını değiştirmen gerekmiyor.

Telefon USB ile bağlıyken, mevcut proje klasöründeki PowerShell terminalinde:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-cloud.ps1
```

Script önce Render HTTPS adresini, sonra **MATCHLY_CLIENT_TOKEN** değerini
gizli girişle sorar. Bu ikinci değer API-Football anahtarı değildir. Script
geçici bir derleme ayar dosyası oluşturur, Flutter'ı başlatır, bittiğinde siler.
Token komut metnine veya kaynak koduna yazılmaz. Her yeniden derlemede bu
scripti kullan; düz `flutter run` varsayılan yerel sunucuya döner.

Bu token deneme sunucusuna erişimi sınırlar. Mobil uygulamadaki değer
çıkarılabilir; herkese açık mağaza sürümünde kullanıcı kimlik doğrulaması ve
kalıcı kota yönetimi ayrıca kurulmalıdır. API-Football anahtarı uygulamada yoktur.

## 4. Bilgisayardan bağımsız bağlantı testi

1. Uygulama telefonda açılınca Flutter terminalinde `q` ile çık.
2. Bilgisayardaki eski `dart run server.dart` terminalini Ctrl+C ile durdur.
3. USB kablosunu çıkar. Telefonun Wi-Fi veya mobil interneti açık olsun.
4. Telefonda uygulamayı tekrar aç; maçları yenile ve Bugün/Yarın programını kontrol et.
5. Ayarlar'da **Özet programını yükle / yenile** ile yeni hatırlatma planını yükle.
   Tam aralık ve takip edilen maç varsa özet oluşur; erişilemeyen hafta için uyarı gösterilir.

## Sınırlar ve hata kontrolü

- Render Free, 15 dakika trafik gelmeyince uyur. Yeni istekte açılması yaklaşık
  bir dakika sürebilir. İlk yükleme bekler; hata alırsan biraz bekleyip Yenile'ye bas.
- Maç verisi bellekte 15 dakika önbelleğe alınır. Sunucu uyuyunca/yeniden başlayınca
  önbellek, tarih kapsamı ve **90 istek/gün süreç sayacı sıfırlanır**. API hesabının
  gerçek kotası sıfırlanmaz. Bu deneme kurulumu tek kullanıcı ve tek sunucu içindir.
- Sunucu internette olsa da uygulama kapalıyken her gün kendiliğinden yeni
  program indirmez. Özetleri yeni günler için uygulamadan yenilemek gerekir.
- `client_auth`: uygulamanın MATCHLY_CLIENT_TOKEN değeri Render ile aynı değil.
- `provider_auth`: Render'daki MATCHLY_FOOTBALL_KEY doğrulanamadı.
- `provider_plan`: sağlayıcı o tarihe veya sezona erişim vermiyor.
- `server_unavailable`: sunucu uyanıyor veya henüz hizmet veremiyor.
- Ücretli plan seçmeden bu kurulum Free ile denenebilir. Free kaynak kullanım
  sınırlarına tabidir ve mağazaya çıkacak bir üretim hizmeti olarak tasarlanmamıştır.

Kaynaklar: https://render.com/docs/free,
https://render.com/docs/docker, https://render.com/docs/web-services,
https://render.com/docs/blueprint-spec.

Sunucu kontrolleri: `dart analyze server.dart server_test.dart cloud_test.dart`,
`dart run server_test.dart`, `dart run cloud_test.dart`.
