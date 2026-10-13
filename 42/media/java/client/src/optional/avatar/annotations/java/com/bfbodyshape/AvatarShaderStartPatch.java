package com.bfbodyshape;

import me.zed_0xff.zombie_buddy.annotations.Patch;
import zombie.core.skinnedmodel.shader.Shader;

@Patch(className = "zombie.core.skinnedmodel.shader.Shader", methodName = "Start", warmUp = true)
public class AvatarShaderStartPatch {
    @Patch.OnExit
    public static void exit(@Patch.This Shader self) {
        BodyShapeState.applyToCurrentAvatar(self);
    }
}
