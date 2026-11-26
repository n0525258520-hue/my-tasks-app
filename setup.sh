set -e
P=app/src/main/java/il/mytasks
mkdir -p app/src/main/assets $P app/src/main/res/drawable
mv index.html app/src/main/assets/

cat > settings.gradle <<'EOF_A'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = 'MyTasks'
include ':app'
EOF_A

cat > build.gradle <<'EOF_B'
plugins { id 'com.android.application' version '8.5.2' apply false }
EOF_B

cat > gradle.properties <<'EOF_C'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=false
EOF_C

cat > app/build.gradle <<'EOF_D'
plugins { id 'com.android.application' }
android {
    namespace 'il.mytasks'
    compileSdk 34
    defaultConfig {
        applicationId 'il.mytasks'
        minSdk 24
        targetSdk 34
        versionCode 1
        versionName '1.0'
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
}
EOF_D

cat > app/src/main/AndroidManifest.xml <<'EOF_E'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <application
        android:label="המשימות שלי"
        android:icon="@drawable/ic_launcher"
        android:allowBackup="true"
        android:supportsRtl="true"
        android:theme="@android:style/Theme.DeviceDefault.Light.NoActionBar">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTask"
            android:configChanges="orientation|screenSize|keyboardHidden|smallestScreenSize|screenLayout|uiMode|layoutDirection">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <receiver android:name=".AlarmReceiver" android:exported="false"/>
        <receiver android:name=".BootReceiver" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>
    </application>
</manifest>
EOF_E

cat > app/src/main/res/drawable/ic_launcher.xml <<'EOF_F'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#1F6F5C"
        android:pathData="M54,54m-50,0a50,50 0,1 1,100 0a50,50 0,1 1,-100 0"/>
    <path
        android:strokeColor="#FFFFFF"
        android:strokeWidth="9"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:pathData="M32,56 L47,71 L77,38"/>
</vector>
EOF_F

cat > $P/MainActivity.java <<'EOF_G'
package il.mytasks;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
    private WebView web;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Notifier.ensureChannel(this);
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }
        web = new WebView(this);
        setContentView(web);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        web.setWebViewClient(new WebViewClient());
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(this), "Android");
        web.loadUrl("file:///android_asset/index.html");
    }

    @Override
    protected void onResume() {
        super.onResume();
        Notifier.foreground = true;
        Notifier.cancelShown(this);
        if (web != null) web.onResume();
    }

    @Override
    protected void onPause() {
        Notifier.foreground = false;
        if (web != null) web.onPause();
        super.onPause();
    }

    @Override
    public void onBackPressed() {
        moveTaskToBack(true);
    }

    static class Bridge {
        private final Context ctx;

        Bridge(Context c) {
            ctx = c.getApplicationContext();
        }

        @JavascriptInterface
        public void sync(String json) {
            Notifier.save(ctx, json);
            Notifier.scheduleAll(ctx);
        }
    }
}
EOF_G

cat > $P/Notifier.java <<'EOF_H'
package il.mytasks;

import android.app.AlarmManager;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import org.json.JSONArray;
import org.json.JSONObject;

public class Notifier {
    static volatile boolean foreground = false;
    static final String CH = "tasks_v1";
    private static final String PREFS = "n";
    private static final long[] OFFS = {0L, 10L * 60000L, 30L * 60000L, 60L * 60000L};

    static void ensureChannel(Context c) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel ch = new NotificationChannel(CH, "תזכורות משימות", NotificationManager.IMPORTANCE_HIGH);
            ch.enableVibration(true);
            ch.setVibrationPattern(new long[]{0, 400, 200, 400, 200, 400});
            Uri u = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
            AudioAttributes aa = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build();
            ch.setSound(u, aa);
            nm.createNotificationChannel(ch);
        }
    }

    static void cancelShown(Context c) {
        NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
        nm.cancelAll();
    }

    static void save(Context c, String json) {
        c.getSharedPreferences(PREFS, 0).edit().putString("json", json).apply();
    }

    private static PendingIntent alarmIntent(Context c, int code, String text, int k) {
        Intent in = new Intent(c, AlarmReceiver.class);
        in.putExtra("text", text);
        in.putExtra("code", code);
        in.putExtra("k", k);
        return PendingIntent.getBroadcast(c, code, in, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    static synchronized void scheduleAll(Context c) {
        AlarmManager am = (AlarmManager) c.getSystemService(Context.ALARM_SERVICE);
        SharedPreferences p = c.getSharedPreferences(PREFS, 0);
        String prev = p.getString("codes", "");
        if (prev.length() > 0) {
            for (String s : prev.split(",")) {
                try {
                    int code = Integer.parseInt(s.trim());
                    am.cancel(alarmIntent(c, code, "", 0));
                } catch (Exception e) {
                    // ignore
                }
            }
        }
        StringBuilder codes = new StringBuilder();
        long now = System.currentTimeMillis();
        try {
            JSONArray a = new JSONArray(p.getString("json", "[]"));
            PendingIntent show = PendingIntent.getActivity(c, 0, new Intent(c, MainActivity.class),
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            for (int i = 0; i < a.length(); i++) {
                JSONObject o = a.getJSONObject(i);
                String id = o.getString("id");
                String text = o.getString("text");
                long at = o.getLong("at");
                for (int k = 0; k < OFFS.length; k++) {
                    long t = at + OFFS[k];
                    if (t <= now + 1000) continue;
                    int code = (id.hashCode() & 0x1fffffff) * 4 + k;
                    am.setAlarmClock(new AlarmManager.AlarmClockInfo(t, show), alarmIntent(c, code, text, k));
                    if (codes.length() > 0) codes.append(",");
                    codes.append(code);
                }
            }
        } catch (Exception e) {
            // ignore bad data
        }
        p.edit().putString("codes", codes.toString()).apply();
    }
}
EOF_H

cat > $P/AlarmReceiver.java <<'EOF_I'
package il.mytasks;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

public class AlarmReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        if (Notifier.foreground) return;
        Notifier.ensureChannel(c);
        String text = i.getStringExtra("text");
        if (text == null) text = "";
        int code = i.getIntExtra("code", 0);
        int k = i.getIntExtra("k", 0);
        Intent open = new Intent(c, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pi = PendingIntent.getActivity(c, code, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            b = new Notification.Builder(c, Notifier.CH);
        } else {
            b = new Notification.Builder(c);
            b.setPriority(Notification.PRIORITY_HIGH);
            b.setDefaults(Notification.DEFAULT_ALL);
        }
        b.setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle(k == 0 ? "⏰ הגיע הזמן" : "⏰ עדיין לא בוצע")
                .setContentText(text)
                .setStyle(new Notification.BigTextStyle().bigText(text))
                .setContentIntent(pi)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_REMINDER);
        NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
        nm.notify(code, b.build());
    }
}
EOF_I

cat > $P/BootReceiver.java <<'EOF_J'
package il.mytasks;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        Notifier.scheduleAll(c);
    }
}
EOF_J
