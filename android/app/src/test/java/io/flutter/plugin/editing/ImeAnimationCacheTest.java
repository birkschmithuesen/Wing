package io.flutter.plugin.editing;

import android.app.Activity;
import android.graphics.Insets;
import android.view.WindowInsets;
import android.view.WindowInsetsAnimation;
import io.flutter.embedding.android.FlutterView;
import java.util.List;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.android.controller.ActivityController;
import org.robolectric.annotation.Config;
import static org.junit.Assert.assertEquals;

/** Replays the captured Android 17 resume sequence against the actual embedding. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35, manifest = Config.NONE)
public class ImeAnimationCacheTest {
    private static WindowInsets insets(int height) {
        return new WindowInsets.Builder()
            .setInsets(WindowInsets.Type.ime(), Insets.of(0, 0, 0, height))
            .setVisible(WindowInsets.Type.ime(), height > 0)
            .setInsets(WindowInsets.Type.navigationBars(), Insets.of(0, 0, 0, 39)).build();
    }
    private static final class Window implements AutoCloseable {
        final ActivityController<Activity> activity = Robolectric.buildActivity(Activity.class).setup();
        final FlutterView view = new FlutterView(activity.get());
        final ImeSyncDeferringInsetsCallback callback = new ImeSyncDeferringInsetsCallback(view);
        Window() { activity.get().setContentView(view); callback.install(); deliver(0); }
        WindowInsetsAnimation prepare() {
            WindowInsetsAnimation a = new WindowInsetsAnimation(WindowInsets.Type.ime(), null, 250);
            view.dispatchWindowInsetsAnimationPrepare(a);
            return a;
        }
        void deliver(int height) { view.dispatchApplyWindowInsets(insets(height)); }
        void progress(WindowInsetsAnimation a, int height) {
            view.dispatchWindowInsetsAnimationProgress(insets(height), List.of(a));
        }
        void end(WindowInsetsAnimation a) { view.dispatchWindowInsetsAnimationEnd(a); }
        void completed(int height) {
            WindowInsetsAnimation a = prepare(); deliver(height); progress(a, height); end(a);
            assertEquals(height, keyboard());
        }
        int keyboard() { return view.getViewportMetrics().viewInsetBottom; }
        public void close() { callback.remove(); activity.close(); }
    }
    @Test public void resumeAnimationWithoutNewInsetsCannotReplayPreviousKeyboardHeight() {
        try (Window w = new Window()) {
            w.completed(883);
            w.deliver(0); // Android applies hidden geometry before the resumed animation.
            assertEquals(0, w.keyboard());
            WindowInsetsAnimation resumed = w.prepare();
            // Phone trace: prepare -> progress -> end, without onApplyWindowInsets.
            w.progress(resumed, 972); w.progress(resumed, 0);
            assertEquals(0, w.keyboard());
            w.end(resumed);
            assertEquals("onEnd must not resurrect the previous animation's cache", 0, w.keyboard());
            assertEquals(39, w.view.getViewportMetrics().viewPaddingBottom);
        }
    }
    @Test public void oldHiddenSnapshotCannotEraseCurrentVisibleKeyboard() {
        try (Window w = new Window()) {
            w.completed(0); w.deliver(883); w.end(w.prepare());
            assertEquals(883, w.keyboard());
        }
    }
    @Test public void ordinaryAnimationDefersTargetAndKeepsIntermediateFrames() {
        try (Window w = new Window()) {
            WindowInsetsAnimation show = w.prepare(); w.deliver(883);
            assertEquals(0, w.keyboard());
            w.progress(show, 400); assertEquals(400, w.keyboard());
            w.end(show); assertEquals(883, w.keyboard());
            WindowInsetsAnimation hide = w.prepare(); w.deliver(0);
            assertEquals(883, w.keyboard());
            w.progress(hide, 200); assertEquals(200, w.keyboard());
            w.end(hide); assertEquals(0, w.keyboard());
        }
    }
    @Test public void consumedInsetsDuringAnimationDoNotOverwriteItsTarget() {
        try (Window w = new Window()) {
            WindowInsetsAnimation show = w.prepare(); w.deliver(883); w.progress(show, 400);
            w.deliver(0); // Consumed geometry redispatched during layout is not a new target.
            w.end(show); assertEquals(883, w.keyboard());
        }
    }
    @Test public void nextAnimationCanCaptureFreshInsetsAfterMissingDelivery() {
        try (Window w = new Window()) {
            w.completed(883); w.deliver(0); w.end(w.prepare());
            w.completed(700); w.completed(0);
        }
    }
}
