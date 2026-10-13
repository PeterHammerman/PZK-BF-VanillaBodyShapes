package com.bfbodyshape;

import me.zed_0xff.zombie_buddy.annotations.Patch;
import zombie.core.skinnedmodel.model.ModelSlotRenderData;
import zombie.core.skinnedmodel.shader.Shader;

/**
 * After the engine has set its own per-model uniforms for a character draw, set ours.
 * slotData.character tells us exactly whose model this draw belongs to.
 */
@Patch(className = "zombie.core.skinnedmodel.shader.Shader", methodName = "startCharacter", warmUp = true)
public class ShaderStartCharacterPatch {
    @Patch.OnExit
    public static void exit(@Patch.This Shader self, @Patch.Argument(0) ModelSlotRenderData slotData) {
        BodyShapeState.applyTo(self, slotData);
    }
}
