# Sunucu 0.12.0 — Puan durumu

Dosyaları GitHub sunucu deposunun köküne yükleyin. Render Live sonrasında /health sürümü 0.12.0 olmalı.
Mevcut ortam değişkenleri aynı; yeni anahtar gerekmez.
GET /leagues/:id/standings mevcut CLIENT_TOKEN ile korunur.
GOAL /v1/leagues/:id/standings yanıtı normalize edilir; gruplar/aşamalar/sezonlar ayrı kalır.
Eksik sayılar null kalır, puan tablosu maç sonuçlarından üretilmez.
15 dakika ortak önbellek kullanılır; aynı futbol sağlayıcısının günlük 900 istek bütçesine dahildir.
standings_test.dart Docker derlemesinde çalışır. Flutter uygulaması 0.14.0+37 ile kullanın.
Gerçek hesap kapsamı, Süper Lig erişimi ve sağlayıcı güncelliği dağıtım sonrası doğrulanmalı.

Önceki notlar:

# Sunucu 0.11.0 — Canlı yenileme

ZIP içindeki dosyaları mevcut GitHub sunucu deposunun köküne yükleyin.
Render Live sonrası /health serverVersion 0.11.0 olmalı. Ortam değişkenlerini koruyun.
Sonra Flutter uygulamasını 0.12.0+33 sürümüne güncelleyin.

Canlı futbol fikstürü ve gol olayları 30 saniye, kadrolar 60 saniye ortak önbellek kullanır.
Yeni yetkilendirmeli /fixtures/:id/score adresi normalize edilmiş tek maç döndürür.
Kadrolarda ?refresh=1 önbelleği ancak 30 saniye geçince yeniler.
Eşzamanlı aynı maç istekleri birleştirilir. Ortak günlük 900 futbol isteği sınırı korunur.
Kota ve sağlayıcı gecikmeleri geçerlidir; bu bir WebSocket/anlık veri garantisi değildir.
Basketbol önbelleği 120 dakika, normal futbol listesi 15 dakika kalır.
Docker derlemesinde refresh_test.dart dahil testler çalışır.

---
Önceki sürümlerin notları (yukarıdaki süreler günceldir):

## 0.10.0 — Kadrolar

Yeni yetkilendirmeli adres: `/fixtures/:id/lineups`. Sağlayıcı anahtarı sunucuda kalır.
Kadrolar ve goller aynı günlük sağlayıcı kotasını kullanır. Kadrolar 5 dakika önbellekte tutulur.
`lineups_test.dart` Docker derlemesinde çalışır. Mevcut ortam değişkenleri aynı kalır.

# 0.9.1: Geçmiş maçlar
Son 7 yerel gün için UTC ve saat dilimi payıyla geriye dönük pencere genişletildi.
Tek istek yine yalnızca bir gün döndürür. Kota değişmedi.

# Sunucu 0.9.0 — Gol olayları
Yeni /fixtures/:id/events servisi mevcut istemci tokenı ile korunur.
GOAL anahtarı sunucuda kalır. Futbol fikstürü ile ortak günlük 900 istek sınırı kullanılır.
Olaylar 5 dakika önbellekte tutulur. Docker altı test grubunu çalıştırır.
API anahtarlarını değiştirmeyin. Render Live sonrası /health sürümü 0.9.0 olmalı.

# Sunucu 0.8.1 — Avrupa kupaları düzeltmesi
Lig aşaması ekleri tanınır, kupa adı uygulama filtresi için sadeleştirilir.
Konferans Ligi eklendi. Takım, maç ve lig kimlikleri korunur.
Dosyaları mevcut GitHub sunucu deposuna yükleyin. Render Live sonrası /health serverVersion 0.8.1 olmalı.
API anahtarlarını değiştirmeyin.

# MATCHLY sunucu 0.8.0 — Basketbol servisi

Bu sürüm mevcut futbol servisini korur ve ayrı `/basketball/fixtures` servisi ekler.
NBA (10996), EuroLeague (102904) ve Türkiye Basketbol Süper Ligi (89288) desteklenir.

## Kurulum
1. Render > matchly-api servisi > Environment bölümüne ekleyin:
   `MATCHLY_HIGHLIGHTLY_KEY` = Highlightly panelindeki API anahtarınız.
   Anahtarı GitHub'a, uygulama koduna veya sohbet ekranına yazmayın.
2. Mevcut MATCHLY_GOAL_KEY ve MATCHLY_CLIENT_TOKEN değerlerini değiştirmeyin.
3. ZIP içindeki dosyaları sunucu GitHub deposunun köküne yükleyin, aynı adlı dosyaları güncelleyin.
4. Render dağıtımının Live olmasını bekleyin.
5. /health yanıtındaki serverVersion: 0.8.0 olmalı.
   Yetkilendirilmiş /health yanıtında basketballConfigured: true da görünür.

Bu paket yalnızca sunucuyu günceller. Telefonda basketbol maçlarının görünmesi için
Flutter uygulamasının bu yeni servisi kullanan sürümü ayrıca hazırlanıp yüklenmelidir.

## Veri ve sınırlar
- İstek: GET /basketball/fixtures?start=<UTC ISO tarih>&end=<UTC ISO tarih>
- Yetkilendirme futbol servisiyle aynı Bearer MATCHLY_CLIENT_TOKEN başlığıdır.
- Yanıtta sport=basketball, namespace içeren maç/takım/lig kimlikleri ve takım logoları vardır.
- Q1–Q4, HT, BT ve OT canlı durumlarıdır; skor bilinmiyorsa null kalır.
- Basketbol ücretsiz planında veriler 120 dakika ortak önbellekte tutulur; anlık skor vaadi yoktur.
- Her sağlayıcı sayfası istek bütçesinden düşer. Sunucu süreci UTC gününde en fazla 90 basketbol isteği yapar.
- Kota sayacı bellektedir; yeniden dağıtımda sıfırlanır. Sağlayıcı kotası bağımsız olarak geçerlidir.
  Sağlayıcı 429 veya kalan kota 0 bildirirse süreç 24 saat basketbol isteği göndermez.
- Eksik sayfalar, erişim kısıtları ve sağlayıcı hataları boş maç listesi gibi sunulmaz.
- Basketbol anahtarı eksik olsa bile futbol servisi çalışır; basketbol servisi açık hata döndürür.

## Doğrulama
Dart analyze ve server_test.dart, cloud_test.dart, live_cache_test.dart,
goal_provider_test.dart, basketball_test.dart çalıştırıldı.
Gerçek anahtarla Render üzerinden erişim, dağıtımdan sonra ayrıca doğrulanmalıdır.

---
Önceki futbol kurulum notları:

# MATCHLY – GOAL API / Dokuz Lig

Bu sürüm Türkiye Süper Lig, Türkiye 1. Lig, Premier League, La Liga, Bundesliga, Serie A, Ligue 1, UEFA Champions League ve UEFA Europa League verisini GOAL API'den alır.
API anahtarı APK'ya veya GitHub'a eklenmez.

## GitHub / Render kurulumu
1. ZIP'i açın. İçteki matchly-server-main klasöründeki dosyaları GitHub deposunun köküne yükleyin. Klasörü iç içe yüklemeyin.
2. Render > matchly-api > Environment bölümünde MATCHLY_GOAL_KEY ekleyin. Değeri GOAL API anahtarınız olsun.
3. MATCHLY_CLIENT_TOKEN değerini koruyun. Telefon uygulaması aynı token ile bağlanır.
4. MATCHLY_PUBLIC_SERVER=true ve mevcut Render hostname/PORT ayarlarını koruyun.
5. Save ve Manual Deploy > Deploy latest commit seçin.
6. Loglarda testlerin geçtiğini ve MATCHLY bulut sunucusu hazir mesajını kontrol edin.
7. /health anonim yanıtta serverVersion 0.7.3 göstermelidir. Yetkili istekte source goal-api görünür.
8. Telefon uygulamasını kapatıp açın, maçları yenileyin. Favori takımları ve lig seçimini yeniden seçin: sağlayıcı kimlikleri değişti.

Sunucu URL'si ve uygulama token'ı aynı kaldıysa APK'yı yeniden derlemek gerekmez.
Eski MATCHLY_FOOTBALL_KEY bu sürümde kullanılmaz; GOAL anahtarını ayrı MATCHLY_GOAL_KEY alanına girin.

## Yenileme ve kullanım
Normal günlük veri 15 dakika, canlı ekran verisi 5 dakika önbellekte tutulur.
Bu sürüm anlık WebSocket veya webhook gol bildirimi sağlamaz.
UTC tarihinin tüm sayfaları kontrol edilir; desteklenen dokuz lig seçilir. Aynı UTC gününde ek ligler için ayrı sayfa istekleri yapılmaz.
Her sayfa bir API isteğidir. Eksik sayfalama veya hata olduğunda kısmi gün başarı olarak döndürülmez.
Güvenli başlangıç sınırı sunucu süreci başına UTC günde 900 gerçek API isteğidir.
Panelde ücretsiz plan 1.000 günlük istek gösteriyor. Sunucu 900 ile sınırlandırılır; kalan 100 istek manuel testler için paydır. Sık yenileme ve çok sayıda gün bu sınırı tüketebilir.
Sayaç/önbellek bellektedir; Render yeniden başlarsa sıfırlanır. Sağlayıcının kendi limiti devam eder.
Ücretsiz planın gerçek günlük kotasını panelden veya X-RateLimit-Limit/Remaining/Reset yanıt başlıklarından doğrulayın.
Üretim yayını öncesinde günlük kotayı, maç kapsamını ve canlı veri gecikmesini ayrıca ölçün.
Saatler kickoffUtc alanından UTC olarak alınır; telefon yerel saate çevirir.
Bilinmeyen skorlar sıfıra çevrilmez. matchLive eski bayrağı yerine maç durumu/dönemi kullanılır.

## Yerel doğrulama
Dart SDK ile:
    dart analyze
    dart run server_test.dart
    dart run cloud_test.dart
    dart run live_cache_test.dart
    dart run goal_provider_test.dart
Docker derlemesi bu dört test dosyasını da çalıştırır.

Ligler ve takımlar uygulamada yüklenen 7 günlük maç programından oluşur. O dönemde maçı olmayan lig listede görünmeyebilir. Eski Süper Lig favorileri korunur; yeni ligleri Takipler bölümünden seçin.
Güncel tarihli tüm ligler anahtar olmadan bu ortamda canlı doğrulanmadı; dağıtım sonrası telefon üzerinden kontrol edin.

0.7.3: Takım logoları home/away.logo alanında uygulamaya aktarılır. Logoları göstermek için güncel uygulama APK’sını da kurun.
