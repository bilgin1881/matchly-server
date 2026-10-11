# MATCHLY – GOAL API / Süper Lig

Bu sürüm yalnızca Türkiye Süper Lig verisini GOAL API'den alır.
API anahtarı APK'ya veya GitHub'a eklenmez.

## GitHub / Render kurulumu
1. ZIP'i açın. İçteki matchly-server-main klasöründeki dosyaları GitHub deposunun köküne yükleyin. Klasörü iç içe yüklemeyin.
2. Render > matchly-api > Environment bölümünde MATCHLY_GOAL_KEY ekleyin. Değeri GOAL API anahtarınız olsun.
3. MATCHLY_CLIENT_TOKEN değerini koruyun. Telefon uygulaması aynı token ile bağlanır.
4. MATCHLY_PUBLIC_SERVER=true ve mevcut Render hostname/PORT ayarlarını koruyun.
5. Save ve Manual Deploy > Deploy latest commit seçin.
6. Loglarda testlerin geçtiğini ve MATCHLY bulut sunucusu hazir mesajını kontrol edin.
7. /health anonim yanıtta serverVersion 0.7.1 göstermelidir. Yetkili istekte source goal-api görünür.
8. Telefon uygulamasını kapatıp açın, maçları yenileyin. Favori takımları ve lig seçimini yeniden seçin: sağlayıcı kimlikleri değişti.

Sunucu URL'si ve uygulama token'ı aynı kaldıysa APK'yı yeniden derlemek gerekmez.
Eski MATCHLY_FOOTBALL_KEY bu sürümde kullanılmaz; GOAL anahtarını ayrı MATCHLY_GOAL_KEY alanına girin.

## Yenileme ve kullanım
Normal günlük veri 15 dakika, canlı ekran verisi 5 dakika önbellekte tutulur.
Bu sürüm anlık WebSocket veya webhook gol bildirimi sağlamaz.
UTC tarihinin tüm sayfaları kontrol edilir; yalnız Süper Lig seçilir.
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
