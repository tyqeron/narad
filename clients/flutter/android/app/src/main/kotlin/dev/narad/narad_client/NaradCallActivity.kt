package dev.narad.narad_client

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.*
import org.json.JSONObject

/** Complete local incoming/ongoing controls when the user chooses the dialer role. */
class NaradCallActivity:Activity() {
    private val main=Handler(Looper.getMainLooper())
    private lateinit var content:LinearLayout
    private var speaker=false
    private var muted=false
    private val refresh=object:Runnable {override fun run(){render();main.postDelayed(this,1000)}}
    override fun onCreate(state:Bundle?){super.onCreate(state);if(android.os.Build.VERSION.SDK_INT>=27){setShowWhenLocked(true);setTurnScreenOn(true)};window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);content=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(32,48,32,32)};setPhoneContent(ScrollView(this).apply{addView(content)})}
    override fun onResume(){super.onResume();main.post(refresh)}
    override fun onPause(){main.removeCallbacks(refresh);super.onPause()}
    private fun render(){
        content.removeAllViews();val calls=NaradInCallService.snapshot()
        if(calls.length()==0){finish();return}
        for(i in 0 until calls.length()) {
            val call=calls.getJSONObject(i);content.addView(TextView(this).apply{text="${call.getString("number")} · ${call.getString("state")}";textSize=24f})
            fun button(label:String,kind:String,args:JSONObject=JSONObject()){content.addView(Button(this).apply{text=label;setOnClickListener{try{NaradInCallService.perform(kind,args.put("call_id",call.getString("id")));if(kind=="mute")muted=args.getBoolean("muted");render()}catch(e:Exception){Toast.makeText(this@NaradCallActivity,e.message,Toast.LENGTH_LONG).show()}}})}
            if(call.getString("state")=="ringing"){button("Answer","answer");button("Decline","reject")} else button("End call","hangup")
            button(if(muted)"Unmute microphone" else "Mute microphone","mute",JSONObject().put("muted",!muted))
            content.addView(Button(this).apply{text=if(speaker)"Use earpiece" else "Use speaker";setOnClickListener{speaker=!speaker;NaradInCallService.speaker(speaker);render()}})
            for(row in listOf("123","456","789","*0#")) {
                val keys=LinearLayout(this)
                for(tone in row)keys.addView(Button(this).apply{text=tone.toString();setOnClickListener{NaradInCallService.perform("dtmf",JSONObject().put("call_id",call.getString("id")).put("tone",tone.toString()))}},LinearLayout.LayoutParams(0,64,1f))
                content.addView(keys)
            }
        }
    }
}
