package dev.narad.narad_client

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.webrtc.AudioTrack
import org.webrtc.AudioTrackSink
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors

/** Only the selected remote track is recorded; unrelated playback is excluded. */
object TrackRecording {
    private val captures=mutableMapOf<String,Wave>()
    private val worker=Executors.newSingleThreadExecutor()
    private val main=Handler(Looper.getMainLooper())
    private fun temporary(path:String):File {
        val file=File(path).canonicalFile
        // Flutter uses a generated narad-camera-* directory in the app cache.
        check(file.parentFile?.name?.startsWith("narad-camera-")==true){"Invalid recording path"}
        return file
    }
    fun handle(context:Context,call:MethodCall,result:MethodChannel.Result):Boolean {
        if(call.method !in listOf("naradAudioStart","naradAudioStop","naradMuxRecording"))return false
        try {
            if(call.method=="naradAudioStart") {
                val id=call.argument<String>("trackId") ?: error("Missing audio track")
                check(captures.size<4 && !captures.containsKey(id)){"Audio already recording"}
                val file=temporary(call.argument<String>("path") ?: error("Missing recording path"))
                check(file.toPath().startsWith(context.cacheDir.canonicalFile.toPath())){"Invalid recording path"}
                val track=FlutterWebRTCPlugin.sharedSingleton.getRemoteTrack(id) as? AudioTrack ?: error("Remote audio track unavailable")
                captures[id]=Wave(track,file);result.success(null)
            } else if(call.method=="naradAudioStop") {
                val id=call.argument<String>("trackId") ?: error("Missing audio track")
                val capture=captures.remove(id) ?: error("Audio recording unavailable")
                capture.detach()
                worker.execute {
                    try {capture.finish();main.post{result.success(null)}}
                    catch(e:Exception){main.post{result.error("audio_recording",e.message,null)}}
                }
            } else {
                val video=temporary(call.argument<String>("video") ?: error("Missing video"))
                val audio=temporary(call.argument<String>("audio") ?: error("Missing audio"))
                val output=temporary(call.argument<String>("output") ?: error("Missing output"))
                for(file in listOf(video,audio,output))check(file.toPath().startsWith(context.cacheDir.canonicalFile.toPath())){"Recording must use app cache"}
                worker.execute {
                    try {mux(video,audio,output);main.post{result.success(null)}}
                    catch(e:Exception){output.delete();main.post{result.error("audio_recording",e.message,null)}}
                }
            }
        } catch(e:Exception){result.error("audio_recording",e.message,null)}
        return true
    }
    private class Wave(private val track:AudioTrack,file:File):AudioTrackSink {
        private val queue=ArrayBlockingQueue<ByteArray>(256)
        private val output=RandomAccessFile(file,"rw")
        private val started=System.nanoTime()
        @Volatile private var stopped=false
        @Volatile private var failure:String?=null
        private var rate=0;private var channels=0;private var written=0L
        private val writer:Thread
        init {
            output.setLength(0);output.write(ByteArray(44))
            writer=Thread({
                try {
                    while(!stopped || queue.isNotEmpty()) {
                        val bytes=queue.poll(100,java.util.concurrent.TimeUnit.MILLISECONDS) ?: continue
                        check(written+bytes.size<=128L*1024*1024){"Audio recording limit reached"}
                        output.write(bytes);written+=bytes.size
                    }
                    check(failure==null && rate>0 && written>0){failure ?: "No remote audio frames"}
                    val header=ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
                    header.put("RIFF".toByteArray()).putInt((written+36).toInt()).put("WAVEfmt ".toByteArray()).putInt(16)
                    header.putShort(1).putShort(channels.toShort()).putInt(rate).putInt(rate*channels*2)
                    header.putShort((channels*2).toShort()).putShort(16).put("data".toByteArray()).putInt(written.toInt())
                    output.seek(0);output.write(header.array())
                } catch(e:Exception){failure=e.message ?: "Audio recording failed"}
                finally{output.close()}
            },"narad-track-recording");writer.start();track.addSink(this)
        }
        @Synchronized override fun onData(data:ByteBuffer,bits:Int,sampleRate:Int,channelCount:Int,frames:Int,timestamp:Long) {
            if(stopped || failure!=null)return
            if(bits!=16 || sampleRate !in 8000..96000 || channelCount !in 1..2 || frames !in 1..9600) {failure="Unsupported remote audio format";return}
            if(rate==0){
                rate=sampleRate;channels=channelCount
                val delay=(System.nanoTime()-started)/1_000_000
                if(delay>3000){failure="Remote audio did not arrive";return}
                val silence=ByteArray(((delay*rate/1000)*channels*2).toInt())
                if(!queue.offer(silence)){failure="Audio recording queue overflow";return}
            }
            if(rate!=sampleRate || channels!=channelCount){failure="Remote audio format changed";return}
            val length=frames*channelCount*2
            if(data.remaining()<length){failure="Invalid remote audio frame";return}
            val bytes=ByteArray(length);data.duplicate().get(bytes)
            if(!queue.offer(bytes))failure="Audio recording queue overflow"
        }
        fun detach(){track.removeSink(this);stopped=true}
        fun finish(){writer.join(10000);check(!writer.isAlive){"Audio writer timed out"};check(failure==null){failure ?: "Audio recording failed"}}
    }
    private fun mux(video:File,audio:File,output:File) {
        val extractor=MediaExtractor();var encoder:MediaCodec?=null;var muxer:MediaMuxer?=null;var muxing=false
        try {
            extractor.setDataSource(video.path)
            val videoIndex=(0 until extractor.trackCount).firstOrNull{extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/")==true} ?: error("No recorded video")
            extractor.selectTrack(videoIndex)
            RandomAccessFile(audio,"r").use {wav ->
                val header=ByteArray(44);wav.readFully(header);val values=ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
                check(String(header,0,4)=="RIFF" && String(header,36,4)=="data"){"Invalid recorded WAV header"}
                val rate=values.getInt(24);val channels=values.getShort(22).toInt();check(rate in 8000..96000 && channels in 1..2){"Invalid recorded WAV format"}
                val format=MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC,rate,channels)
                format.setInteger(MediaFormat.KEY_AAC_PROFILE,MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                format.setInteger(MediaFormat.KEY_BIT_RATE,128000)
                val codec=MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);encoder=codec
                codec.configure(format,null,null,MediaCodec.CONFIGURE_FLAG_ENCODE);codec.start()
                val target=MediaMuxer(output.path,MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);muxer=target
                val vtrack=target.addTrack(extractor.getTrackFormat(videoIndex));var atrack=-1
                var inputDone=false;var outputDone=false;var samples=0L;var progress=System.nanoTime()
                val info=MediaCodec.BufferInfo()
                while(!outputDone){
                    check(System.nanoTime()-progress<30_000_000_000L){"Audio encoder stalled"}
                    if(!inputDone){
                        val index=codec.dequeueInputBuffer(10000)
                        if(index>=0){
                            val buffer=codec.getInputBuffer(index)!!;buffer.clear()
                            val bytes=ByteArray((minOf(buffer.remaining(),16384)/(channels*2))*(channels*2))
                            val count=wav.read(bytes)
                            if(count<0){codec.queueInputBuffer(index,0,0,samples*1_000_000/rate,MediaCodec.BUFFER_FLAG_END_OF_STREAM);inputDone=true}
                            else {buffer.put(bytes,0,count);codec.queueInputBuffer(index,0,count,samples*1_000_000/rate,0);samples+=count/(channels*2)}
                            progress=System.nanoTime()
                        }
                    }
                    val index=codec.dequeueOutputBuffer(info,10000)
                    if(index==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED){atrack=target.addTrack(codec.outputFormat);target.start();muxing=true;progress=System.nanoTime()}
                    else if(index>=0){
                        if(info.size>0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG==0){
                            check(muxing && atrack>=0){"AAC format not ready"};val buffer=codec.getOutputBuffer(index)!!;buffer.position(info.offset);buffer.limit(info.offset+info.size);target.writeSampleData(atrack,buffer,info)
                        }
                        outputDone=info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM!=0
                        codec.releaseOutputBuffer(index,false);progress=System.nanoTime()
                    }
                }
                check(muxing){"No AAC output format"}
                val videoBuffer=ByteBuffer.allocate(8*1024*1024)
                while(true){
                    videoBuffer.clear();val size=extractor.readSampleData(videoBuffer,0);if(size<0)break
                    check(size<=videoBuffer.capacity()){"Video sample exceeds recording limit"}
                    info.set(0,size,extractor.sampleTime,if(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC!=0)MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    target.writeSampleData(vtrack,videoBuffer,info);extractor.advance()
                }
                target.stop();muxing=false
            }
        } finally {
            extractor.release();try{encoder?.stop()}catch(_:Exception){};encoder?.release()
            if(muxing)try{muxer?.stop()}catch(_:Exception){};muxer?.release()
        }
    }
}
