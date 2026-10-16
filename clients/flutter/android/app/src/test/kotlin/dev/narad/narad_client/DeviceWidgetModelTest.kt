package dev.narad.narad_client
import org.junit.Assert.*
import org.junit.Test

class DeviceWidgetModelTest {
    @Test fun allActionsAvailableWithoutPresets() {
        assertEquals(10,DeviceWidgetModel.actionsFor("linux").size)
        assertTrue(DeviceWidgetModel.actionsFor("android").any{it.id=="command"})
        assertEquals(11,DeviceWidgetModel.actions.map{it.id}.distinct().size)
    }
    @Test fun phoneActionsRespectPlatforms(){
        assertTrue(DeviceWidgetModel.actionsFor("android").any{it.id=="phone"})
        assertFalse(DeviceWidgetModel.actionsFor("linux").any{it.id=="phone"})
        assertFalse(DeviceWidgetModel.actionsFor("ios").any{it.id in listOf("command","lock","unlock")})
    }
    @Test fun windowsDoesNotAdvertiseUnlock() {
        assertFalse(DeviceWidgetModel.actionsFor("windows").any{it.id=="unlock"})
    }
    @Test fun offlineDevicesKeepOnlyManagementActions() {
        for(action in DeviceWidgetModel.actions) {
            assertEquals(action.id=="settings" || action.id=="unpair",DeviceWidgetModel.enabled(action.id,false))
            assertTrue(DeviceWidgetModel.enabled(action.id,true))
        }
    }
    @Test fun notificationNamesAndCountsTrackLiveConnections() {
        assertEquals("Narad · No devices connected",DeviceWidgetModel.title(emptyList()))
        assertEquals("Narad · 1 device connected",DeviceWidgetModel.title(listOf("Laptop")))
        assertEquals("Narad · 2 devices connected",DeviceWidgetModel.title(listOf("Phone","Laptop")))
        assertEquals("Connected to Laptop, Phone",DeviceWidgetModel.details(listOf("Phone","Laptop")))
        assertEquals("Ready for your paired devices",DeviceWidgetModel.details(emptyList()))
    }
    @Test fun unknownActionsAreNeverExecuted(){assertFalse(DeviceWidgetModel.known("shell"))}
}
