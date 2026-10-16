package dev.narad.narad_client

import android.app.Activity
import android.os.Bundle
import android.telecom.TelecomManager
import android.widget.*
import android.net.Uri

class NaradDialActivity:Activity() {
    override fun onCreate(state:Bundle?){
        super.onCreate(state)
        val layout=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(32,48,32,32)}
        layout.addView(TextView(this).apply{text="Narad Phone";textSize=26f})
        val number=EditText(this).apply{hint="Phone number";inputType=android.text.InputType.TYPE_CLASS_PHONE;setText(intent.data?.schemeSpecificPart ?: "")};layout.addView(number)
        layout.addView(Button(this).apply{text="Call";setOnClickListener{try{
            check(NaradInCallService.isDefault(this@NaradDialActivity)){"Select Narad as your default phone app in Phone integration"}
            val destination=PhoneBridge.number(number.text.toString())
            getSystemService(TelecomManager::class.java).placeCall(Uri.fromParts("tel",destination,null),Bundle())
        }catch(e:Exception){Toast.makeText(this@NaradDialActivity,e.message,Toast.LENGTH_LONG).show()}}})
        layout.addView(Button(this).apply{text="Active call";setOnClickListener{startActivity(android.content.Intent(this@NaradDialActivity,NaradCallActivity::class.java))}})
        setContentView(layout)
    }
}
