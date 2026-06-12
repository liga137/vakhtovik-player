package libbox

/**
 * Минимальный JNI-биндинг для libbox.so (sing-box).
 * 
 * libbox.so извлекается из SFA APK в CI (build.yml) и кладётся в jniLibs/.
 * 
 * JNI-функции в .so именуются по стандартной схеме:
 *   Java_libbox_BoxService_start
 *   Java_libbox_BoxService_stop
 * 
 * @JvmStatic генерирует статические методы, матчащиеся с этими именами.
 */
object BoxService {

    init {
        System.loadLibrary("box")
    }

    /**
     * Запуск sing-box с перехватом трафика через TUN-интерфейс.
     * @param configJson  конфиг sing-box в JSON
     * @param tunFd       файловый дескриптор TUN (из VpnService.Builder.establish())
     * @param tempDir     рабочая директория (context.filesDir)
     * @return null при успехе, строка с ошибкой при неудаче
     */
    @JvmStatic
    external fun start(configJson: String, tunFd: Int, tempDir: String): String?

    /**
     * Остановка sing-box и освобождение ресурсов.
     */
    @JvmStatic
    external fun stop()
}
