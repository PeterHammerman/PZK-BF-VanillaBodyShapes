package com.bfbodyshape;

import me.zed_0xff.zombie_buddy.annotations.Patch;
import zombie.core.skinnedmodel.advancedanimation.AnimatedModel;

@Patch(className = "zombie.core.skinnedmodel.advancedanimation.AnimatedModel", methodName = "DrawCharSingular", warmUp = true)
public class AvatarDrawScopePatch {
    @Patch.OnEnter
    public static void enter(@Patch.Argument(0) AnimatedModel.AnimatedModelInstanceRenderData data) {
        BodyShapeState.beginAvatarDraw(data);
    }

    @Patch.OnExit
    public static void exit() {
        BodyShapeState.endAvatarDraw();
    }
}
