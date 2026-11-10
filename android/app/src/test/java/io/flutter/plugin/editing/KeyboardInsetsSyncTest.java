package io.flutter.plugin.editing;

import android.app.Activity;
import android.graphics.Insets;
import android.os.Looper;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsAnimation;
import com.tarkilhk.wing.KeyboardInsetsSync;
import io.flutter.embedding.android.FlutterView;
import java.util.List;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.android.controller.ActivityController;
import org.robolectric.annotation.Config;
import static org.junit.Assert.assertEquals;

/** Exercises shipped Flutter deferral, not a second implementation of its behavior. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35, manifest = Config.NONE)
public class KeyboardInsetsSyncTest {
    private static WindowInsets insets(int keyboard) {
        return new WindowInsets.Builder()
            .setInsets(WindowInsets.Type.ime(), Insets.of(0, 0, 0, keyboard))
            .setVisible(WindowInsets.Type.ime(), keyboard > 0)
            .setInsets(WindowInsets.Type.navigationBars(), Insets.of(0, 0, 0, 39))
            .build();
    }

    private static final class Window implements AutoCloseable {
        final ActivityController<Activity> activity = Robolectric.buildActivity(Activity.class).setup().visible();
        final View root = activity.get().getWindow().getDecorView();
        WindowInsets current = insets(0);
        final FlutterView view = new FlutterView(activity.get()) {
            @Override public WindowInsets getRootWindowInsets() { return current; }
        };
        final KeyboardInsetsSync sync;

        Window() {
            activity.get().setContentView(view);
            new ImeSyncDeferringInsetsCallback(view).install();
            activity.visible();
            activity.windowFocusChanged(true);
            sync = new KeyboardInsetsSync(activity.get());
            view.onApplyWindowInsets(current);
        }

        WindowInsetsAnimation begin(int finalKeyboard) {
            WindowInsetsAnimation animation = new WindowInsetsAnimation(WindowInsets.Type.ime(), null, 250);
            // Robolectric does not traverse from the decor to FlutterView here.
            // Deliver both callbacks in Android's parent-before-child order.
            root.dispatchWindowInsetsAnimationPrepare(animation);
            view.dispatchWindowInsetsAnimationPrepare(animation);
            deliver(finalKeyboard);
            return animation;
        }

        void deliver(int keyboard) {
            current = insets(keyboard);
            view.dispatchApplyWindowInsets(current);
        }

        void progress(WindowInsetsAnimation animation, int keyboard) {
            root.dispatchWindowInsetsAnimationProgress(insets(keyboard), List.of(animation));
            view.dispatchWindowInsetsAnimationProgress(insets(keyboard), List.of(animation));
        }

        void end(WindowInsetsAnimation animation) {
            root.dispatchWindowInsetsAnimationEnd(animation);
            view.dispatchWindowInsetsAnimationEnd(animation);
        }
        void settle() { Shadows.shadowOf(Looper.getMainLooper()).idle(); }
        int keyboard() { return view.getViewportMetrics().viewInsetBottom; }

        @Override public void close() { sync.close(); activity.close(); }
    }

    @Test public void interruptedImeAnimationUsesCurrentWindowInsets() {
        try (Window window = new Window()) {
            WindowInsetsAnimation animation = window.begin(883);
            window.deliver(0);
            window.end(animation);
            assertEquals("Flutter replays the obsolete deferred snapshot before settlement", 883, window.keyboard());
            window.settle();
            assertEquals("A hidden keyboard must not leave its old height in Flutter", 0, window.keyboard());
            assertEquals(39, window.view.getViewportMetrics().viewPaddingBottom);
        }
    }

    @Test public void newlyVisibleKeyboardIsNotClearedByAnOlderHide() {
        try (Window window = new Window()) {
            window.deliver(883);
            WindowInsetsAnimation animation = window.begin(0);
            window.deliver(883);
            window.end(animation);
            assertEquals(0, window.keyboard());
            window.settle();
            assertEquals(883, window.keyboard());
        }
    }

    @Test public void activeAnimationKeepsItsIntermediateGeometry() {
        try (Window window = new Window()) {
            WindowInsetsAnimation animation = window.begin(883);
            window.progress(animation, 400);
            window.sync.onWindowFocusChanged(true);
            window.settle();
            assertEquals(400, window.keyboard());
            window.end(animation);
            window.settle();
            assertEquals(883, window.keyboard());
        }
    }

    @Test public void overlappingAnimationsSettleOnlyAfterTheLastEnd() {
        try (Window window = new Window()) {
            WindowInsetsAnimation first = window.begin(883);
            WindowInsetsAnimation second = window.begin(883);
            window.deliver(0);
            window.end(first);
            window.settle();
            assertEquals(883, window.keyboard());
            window.end(second);
            window.settle();
            assertEquals(0, window.keyboard());
        }
    }

    @Test public void focusRecoveryRepairsAnAnimationWithNoEndCallback() {
        try (Window window = new Window()) {
            WindowInsetsAnimation animation = window.begin(883);
            window.progress(animation, 883);
            window.sync.onWindowFocusChanged(false);
            window.deliver(0);
            window.settle();
            assertEquals(883, window.keyboard());
            window.sync.onWindowFocusChanged(true);
            window.settle();
            assertEquals(0, window.keyboard());
        }
    }

    @Test public void startingAnotherAnimationCancelsPendingSettlement() {
        try (Window window = new Window()) {
            WindowInsetsAnimation first = window.begin(883);
            window.deliver(0);
            window.end(first);
            WindowInsetsAnimation next = window.begin(883);
            window.progress(next, 200);
            window.settle();
            assertEquals(200, window.keyboard());
            window.end(next);
            window.settle();
            assertEquals(883, window.keyboard());
        }
    }

    @Test public void retiredActivityCannotWriteToItsFlutterView() {
        try (Window window = new Window()) {
            WindowInsetsAnimation animation = window.begin(883);
            window.deliver(0);
            window.end(animation);
            window.sync.close();
            window.settle();
            window.sync.onWindowFocusChanged(true);
            window.settle();
            assertEquals(883, window.keyboard());
        }
    }
}
