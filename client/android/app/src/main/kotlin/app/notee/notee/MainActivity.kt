package app.notee.notee

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val LOCK_METHOD_CHANNEL   = "notee/lock"
        private const val LOCK_EVENT_CHANNEL    = "notee/lock_events"
        private const val FILE_SAVER_CHANNEL    = "notee/file_saver"
        private const val REQ_SAVE_FILE         = 1001
        private const val ACTION_HANDOFF_REQUEST = "app.notee.notee.HANDOFF_REQUEST"
        private const val ACTION_HANDOFF_ACK     = "app.notee.notee.HANDOFF_ACK"
        private const val ACTION_LIBRARY_CHANGED = "app.notee.notee.LIBRARY_CHANGED"
        private const val ACTION_TOOL_CHANGED    = "app.notee.notee.TOOL_CHANGED"
        private const val EXTRA_TARGET  = "target_session"
        private const val EXTRA_SOURCE  = "source_session"
        private const val EXTRA_NOTE_ID = "note_id"
    }

    private var eventSink: EventChannel.EventSink? = null

    // Held between ACTION_CREATE_DOCUMENT launch and onActivityResult.
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveBytes:  ByteArray? = null

    private val lockReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            Log.d("NoteeLock", "RX action=${intent.action} extras=${intent.extras?.keySet()?.joinToString()} sinkAlive=${eventSink != null}")
            when (intent.action) {
                ACTION_HANDOFF_REQUEST -> {
                    val target = intent.getStringExtra(EXTRA_TARGET) ?: return
                    val source = intent.getStringExtra(EXTRA_SOURCE) ?: return
                    val noteId = intent.getStringExtra(EXTRA_NOTE_ID) ?: return
                    eventSink?.success(mapOf(
                        "type"      to "handoffRequest",
                        "target"    to target,
                        "source"    to source,
                        "noteId"    to noteId,
                    ))
                }
                ACTION_HANDOFF_ACK -> {
                    val target = intent.getStringExtra(EXTRA_TARGET) ?: return
                    val source = intent.getStringExtra(EXTRA_SOURCE) ?: return
                    val noteId = intent.getStringExtra(EXTRA_NOTE_ID) ?: return
                    eventSink?.success(mapOf(
                        "type"      to "handoffAck",
                        "target"    to target,
                        "source"    to source,
                        "noteId"    to noteId,
                    ))
                }
                ACTION_LIBRARY_CHANGED -> {
                    val source = intent.getStringExtra(EXTRA_SOURCE) ?: return
                    eventSink?.success(mapOf(
                        "type"   to "libraryChanged",
                        "source" to source,
                    ))
                }
                ACTION_TOOL_CHANGED -> {
                    val source = intent.getStringExtra(EXTRA_SOURCE) ?: return
                    eventSink?.success(mapOf(
                        "type"   to "toolChanged",
                        "source" to source,
                    ))
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register broadcast receiver.
        val filter = IntentFilter().apply {
            addAction(ACTION_HANDOFF_REQUEST)
            addAction(ACTION_HANDOFF_ACK)
            addAction(ACTION_LIBRARY_CHANGED)
            addAction(ACTION_TOOL_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(lockReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(lockReceiver, filter)
        }

        // Method channel: Dart → Native calls.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCK_METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendHandoffRequest" -> {
                        val target = call.argument<String>("targetSession") ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                        val source = call.argument<String>("sourceSession") ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                        val noteId = call.argument<String>("noteId") ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                        Log.d("NoteeLock", "TX HANDOFF_REQUEST target=$target source=$source noteId=$noteId")
                        sendBroadcast(Intent(ACTION_HANDOFF_REQUEST).apply {
                            setPackage(packageName)
                            putExtra(EXTRA_TARGET, target)
                            putExtra(EXTRA_SOURCE, source)
                            putExtra(EXTRA_NOTE_ID, noteId)
                        })
                        result.success(null)
                    }
                    "sendHandoffAck" -> {
                        val target = call.argument<String>("targetSession") ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                        val source = call.argument<String>("sourceSession") ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                        val noteId = call.argument<String>("noteId") ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                        sendBroadcast(Intent(ACTION_HANDOFF_ACK).apply {
                            setPackage(packageName)
                            putExtra(EXTRA_TARGET, target)
                            putExtra(EXTRA_SOURCE, source)
                            putExtra(EXTRA_NOTE_ID, noteId)
                        })
                        result.success(null)
                    }
                    "broadcastLibraryChanged" -> {
                        val source = call.argument<String>("sourceSession") ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                        Log.d("NoteeLock", "TX LIBRARY_CHANGED source=$source")
                        sendBroadcast(Intent(ACTION_LIBRARY_CHANGED).apply {
                            setPackage(packageName)
                            putExtra(EXTRA_SOURCE, source)
                        })
                        result.success(null)
                    }
                    "broadcastToolChanged" -> {
                        val source = call.argument<String>("sourceSession") ?: return@setMethodCallHandler result.error("BAD_ARGS", null, null)
                        sendBroadcast(Intent(ACTION_TOOL_CHANGED).apply {
                            setPackage(packageName)
                            putExtra(EXTRA_SOURCE, source)
                        })
                        result.success(null)
                    }
                    "openNewWindow" -> {
                        val intent = Intent(this, MainActivity::class.java).apply {
                            addFlags(
                                Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_MULTIPLE_TASK or
                                Intent.FLAG_ACTIVITY_NEW_DOCUMENT
                            )
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // File saver channel: shows ACTION_CREATE_DOCUMENT dialog, writes bytes.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_SAVER_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "saveFile") { result.notImplemented(); return@setMethodCallHandler }
                val bytes    = call.argument<ByteArray>("bytes")   ?: return@setMethodCallHandler result.error("BAD_ARGS", "bytes missing", null)
                val fileName = call.argument<String>("fileName")   ?: return@setMethodCallHandler result.error("BAD_ARGS", "fileName missing", null)
                val mimeType = call.argument<String>("mimeType")   ?: "application/octet-stream"
                pendingSaveResult = result
                pendingSaveBytes  = bytes
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mimeType
                    putExtra(Intent.EXTRA_TITLE, fileName)
                }
                startActivityForResult(intent, REQ_SAVE_FILE)
            }

        // Event channel: Native → Dart events.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOCK_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_SAVE_FILE) return
        val result = pendingSaveResult ?: return
        val bytes  = pendingSaveBytes
        pendingSaveResult = null
        pendingSaveBytes  = null
        if (resultCode == Activity.RESULT_OK && data?.data != null) {
            try {
                contentResolver.openOutputStream(data.data!!)?.use { stream ->
                    stream.write(bytes ?: byteArrayOf())
                    stream.flush()
                }
                result.success(true)
            } catch (e: Exception) {
                result.error("WRITE_FAILED", e.message, null)
            }
        } else {
            result.success(false) // user cancelled
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try { unregisterReceiver(lockReceiver) } catch (_: Exception) {}
    }
}
