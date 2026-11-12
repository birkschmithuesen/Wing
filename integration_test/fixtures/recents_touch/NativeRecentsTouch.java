import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;
import java.lang.reflect.Method;

/** API 36 shell-only input driver. Never linked into Wing or a phone build. */
public final class NativeRecentsTouch {
    private static Object input;
    private static Method inject;
    private static long down;

    private static void send(int action, float[][] positions, long at) throws Exception {
        send(action, positions, at, 2);
    }

    private static void send(int action, float[][] positions, long at, int mode) throws Exception {
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[positions.length];
        MotionEvent.PointerCoords[] coordinates = new MotionEvent.PointerCoords[positions.length];
        for (int i = 0; i < positions.length; i++) {
            properties[i] = new MotionEvent.PointerProperties();
            properties[i].id = i;
            properties[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coordinates[i] = new MotionEvent.PointerCoords();
            coordinates[i].x = positions[i][0];
            coordinates[i].y = positions[i][1];
            coordinates[i].pressure = 1;
            coordinates[i].size = .1f;
        }
        MotionEvent event = MotionEvent.obtain(down, at, action,
                positions.length, properties, coordinates, 0, 0, 1, 1, 0, 0,
                InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            if (!((Boolean) inject.invoke(input, event, mode))) {
                throw new IllegalStateException("Android refused the touch event");
            }
        } finally {
            event.recycle();
        }
    }

    private static void drag(float[][] start, float[][] end, int milliseconds) throws Exception {
        down = SystemClock.uptimeMillis();
        send(MotionEvent.ACTION_DOWN, new float[][]{start[0]}, down);
        if (start.length == 2) {
            SystemClock.sleep(20);
            send(MotionEvent.ACTION_POINTER_DOWN | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    start, SystemClock.uptimeMillis());
        }
        long began = SystemClock.uptimeMillis();
        for (int step = 1; step <= 24; step++) {
            long at = began + milliseconds * step / 24;
            SystemClock.sleep(Math.max(0, at - SystemClock.uptimeMillis()));
            float[][] point = new float[start.length][2];
            for (int p = 0; p < point.length; p++) {
                for (int axis = 0; axis < 2; axis++) {
                    point[p][axis] = start[p][axis] + (end[p][axis] - start[p][axis]) * step / 24f;
                }
            }
            // Deliver intermediate samples separately; Android can coalesce a
            // fully queued flick into one move, losing its velocity history.
            // Queue the final move and release together so processing that last
            // move cannot introduce a pause before finger release.
            send(MotionEvent.ACTION_MOVE, point, at, step == 24 ? 0 : 2);
        }
        long released = began + milliseconds;
        if (start.length == 2) {
            send(MotionEvent.ACTION_POINTER_UP | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    end, released, 0);
        }
        send(MotionEvent.ACTION_UP, new float[][]{end[0]}, released, 0);
    }

    public static void main(String[] args) throws Exception {
        Class<?> manager = Class.forName("android.hardware.input.InputManagerGlobal");
        input = manager.getMethod("getInstance").invoke(null);
        inject = manager.getMethod("injectInputEvent", InputEvent.class, int.class);
        String mode = args[0];
        int count = mode.equals("two") || mode.equals("interrupt") ? 2 : 1;
        float[][] start = new float[count][2], end = new float[count][2];
        int cursor = 1;
        for (int p = 0; p < count; p++) {
            start[p][0] = Float.parseFloat(args[cursor++]);
            start[p][1] = Float.parseFloat(args[cursor++]);
            end[p][0] = Float.parseFloat(args[cursor++]);
            end[p][1] = Float.parseFloat(args[cursor++]);
        }
        int duration = Integer.parseInt(args[cursor++]);
        long started = SystemClock.uptimeMillis();
        if (mode.equals("interrupt")) {
            float shortDx = Float.parseFloat(args[cursor]);
            float[][] shortEnd = {{start[0][0] + shortDx, start[0][1]},
                    {start[1][0] + shortDx, start[1][1]}};
            drag(start, shortEnd, 180);
            SystemClock.sleep(70);
        }
        drag(start, end, duration);
        System.out.println("nativeTouchElapsedMs=" + (SystemClock.uptimeMillis() - started));
    }
}
