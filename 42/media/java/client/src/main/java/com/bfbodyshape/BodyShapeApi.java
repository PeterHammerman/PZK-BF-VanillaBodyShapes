package com.bfbodyshape;

import se.krka.kahlua.integration.annotations.LuaMethod;
import zombie.characters.IsoGameCharacter;

/** Global Lua functions (no @Exposer.LuaClass needed for static @LuaMethod(global = true)). */
public class BodyShapeApi {

    /**
     * BFMDB_SetBodyShape(player, enabled, lactation01, pregnancy01)
     * Call from the game thread. enabled=false (or player=nil) shapes nobody.
     */
    @LuaMethod(name = "BFMDB_SetBodyShape", global = true)
    public static void setBodyShape(IsoGameCharacter chr, boolean enabled, double lactation, double pregnancy) {
        BodyShapeState.set(chr, enabled, lactation, pregnancy);
    }

    /** BFMDB_SetAvatarPatch(true/false): enable the optional UI-avatar path (off by default, per session). */
    @LuaMethod(name = "BFMDB_SetAvatarPatch", global = true)
    public static void setAvatarPatch(boolean on) {
        BodyShapeState.setAvatarEnabled(on);
    }

    /** print(BFMDB_BodyShapeStatus()) in the Lua debug console to see whether the hook is firing. */
    @LuaMethod(name = "BFMDB_BodyShapeStatus", global = true)
    public static String status() {
        return BodyShapeState.status();
    }
}
