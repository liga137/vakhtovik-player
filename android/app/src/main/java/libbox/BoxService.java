package libbox;

/**
 * JNI-мост к libbox.so (из SFA APK).
 * Имена методов должны совпадать с экспортами libbox.so.
 */
public class BoxService {
    static {
        System.loadLibrary("box");
    }

    /** Запустить sing-box с JSON-конфигом и TUN fd. Возвращает null при успехе, иначе текст ошибки. */
    public static native String start(String configJson, int tunFd, String workingDir);

    /** Остановить sing-box. */
    public static native void stop();
}
