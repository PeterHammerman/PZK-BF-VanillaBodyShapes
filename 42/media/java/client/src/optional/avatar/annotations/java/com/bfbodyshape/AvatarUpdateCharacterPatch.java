package com.bfbodyshape;

import me.zed_0xff.zombie_buddy.annotations.Patch;
import zombie.core.skinnedmodel.advancedanimation.AnimatedModel;
import zombie.core.skinnedmodel.model.ModelInstanceRenderData;
import zombie.core.skinnedmodel.shader.Shader;

/**
 * UI avatars (health panel paper doll, etc.) set their per-model uniforms through
 * UpdateCharacter(Shader) instead of Shader.startCharacter. Patch it too so the avatar
 * matches the world model. The world-render subclass (ModelInstanceRenderData) inherits
 * this method, so it is flagged and only allowed an exact character match.
 */
@Patch(className = "zombie.core.skinnedmodel.advancedanimation.AnimatedModel$AnimatedModelInstanceRenderData", methodName = "UpdateCharacter", warmUp = true)
public class AvatarUpdateCharacterPatch {
    @Patch.OnExit
    public static void exit(@Patch.This AnimatedModel.AnimatedModelInstanceRenderData self,
                            @Patch.Argument(0) Shader shader) {
        BodyShapeState.applyToAvatar(shader, self.modelInstance, self instanceof ModelInstanceRenderData);
    }
}
