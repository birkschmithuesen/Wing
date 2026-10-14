#!/usr/bin/env python3
"""Checks a sherpa-onnx Android AAR for what Wing's vad route needs.

Usage: python3 -I tools/voice/check_sherpa_aar.py <path-to-aar> <expected-sha256>
Prints one line per check and exits 1 if any check fails.
"""
import hashlib
import io
import sys
import zipfile

NEEDED_CLASSES = {
    "com/k2fsa/sherpa/onnx/Vad.class": [b"compute", b"acceptWaveform", b"release"],
    "com/k2fsa/sherpa/onnx/SileroVadModelConfig.class": [b"windowSize"],
    "com/k2fsa/sherpa/onnx/VadModelConfig.class": [b"sileroVadModelConfig"],
    "com/k2fsa/sherpa/onnx/OfflineRecognizer.class": [b"createStream", b"decode", b"getResult"],
    "com/k2fsa/sherpa/onnx/OfflineStream.class": [b"acceptWaveform"],
    "com/k2fsa/sherpa/onnx/OfflineModelConfig.class": [b"modelType", b"transducer"],
    "com/k2fsa/sherpa/onnx/OfflineTransducerModelConfig.class": [b"encoder", b"joiner"],
    "com/k2fsa/sherpa/onnx/OfflineRecognizerConfig.class": [b"featConfig", b"decodingMethod"],
    "com/k2fsa/sherpa/onnx/FeatureConfig.class": [b"featureDim"],
}
NEEDED_LIBS = ["jni/arm64-v8a/libsherpa-onnx-jni.so"]


def main(path: str, expected: str) -> int:
    ok = True
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    print(f"sha256 {digest} {'OK' if digest == expected else 'MISMATCH'}")
    ok &= digest == expected
    aar = zipfile.ZipFile(path)
    names = set(aar.namelist())
    for lib in NEEDED_LIBS:
        size = aar.getinfo(lib).file_size if lib in names else 0
        print(f"lib {lib} {'OK ' + str(size) if size else 'MISSING'}")
        ok &= bool(size)
    for name in sorted(n for n in names if n.startswith("jni/arm64-v8a/")):
        print(f"arm64 {name} {aar.getinfo(name).file_size}")
    if "classes.jar" not in names:
        print("classes.jar MISSING")
        return 1
    jar = zipfile.ZipFile(io.BytesIO(aar.read("classes.jar")))
    jar_names = set(jar.namelist())
    for cls, members in NEEDED_CLASSES.items():
        if cls not in jar_names:
            print(f"class {cls} MISSING")
            ok = False
            continue
        data = jar.read(cls)
        missing = [m.decode() for m in members if m not in data]
        print(f"class {cls} {'OK' if not missing else 'MISSING ' + ','.join(missing)}")
        ok &= not missing
    proguard = [n for n in names if n.endswith("proguard.txt")]
    print(f"consumer-proguard {'present' if proguard else 'absent'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
