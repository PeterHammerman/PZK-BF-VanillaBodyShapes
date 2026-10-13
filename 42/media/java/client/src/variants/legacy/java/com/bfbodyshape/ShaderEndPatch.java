package com.bfbodyshape;

import me.zed_0xff.zombie_buddy.Patch;
import zombie.core.skinnedmodel.shader.Shader;

/**
 * GL uniforms persist on the program between draws. Zero ours before the program is unbound so
 * a draw that never goes through startCharacter (e.g. UI avatars) can't inherit stale values.
 */
@Patch(className = "zombie.core.skinnedmodel.shader.Shader", methodName = "End", warmUp = true)
public class ShaderEndPatch {
    @Patch.OnEnter
    public static void enter(@Patch.This Shader self) {
        BodyShapeState.reset(self);
    }
}
