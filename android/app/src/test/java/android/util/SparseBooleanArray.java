package android.util;

import java.util.TreeMap;

/**
 * JVM-test stand-in for the framework class (the mockable android.jar throws "not mocked"), so
 * Media3's Player.Commands / FlagSet work in plain unit tests. Behaviour mirrors the real one.
 */
public class SparseBooleanArray {
    private final TreeMap<Integer, Boolean> map = new TreeMap<>();

    public SparseBooleanArray() {}

    public SparseBooleanArray(int initialCapacity) {}

    public boolean get(int key) { return map.getOrDefault(key, false); }

    public boolean get(int key, boolean valueIfKeyNotFound) { return map.getOrDefault(key, valueIfKeyNotFound); }

    public void put(int key, boolean value) { map.put(key, value); }

    public void append(int key, boolean value) { map.put(key, value); }

    public void delete(int key) { map.remove(key); }

    public int size() { return map.size(); }

    public int keyAt(int index) { return (int) map.keySet().toArray()[index]; }

    public boolean valueAt(int index) { return (boolean) map.values().toArray()[index]; }

    public int indexOfKey(int key) {
        int i = 0;
        for (int k : map.keySet()) { if (k == key) return i; i++; }
        return -1;
    }

    public void clear() { map.clear(); }

    @Override public boolean equals(Object o) { return o instanceof SparseBooleanArray && ((SparseBooleanArray) o).map.equals(map); }

    @Override public int hashCode() { return map.hashCode(); }

    @Override public SparseBooleanArray clone() {
        SparseBooleanArray c = new SparseBooleanArray();
        c.map.putAll(map);
        return c;
    }
}
