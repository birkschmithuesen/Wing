# sherpa-onnx: JNI reads Kotlin config fields and constructs result classes by name.
-keep class com.k2fsa.sherpa.onnx.** { *; }
# commons-compress optional codecs Wing never uses (only bzip2 + tar).
-dontwarn org.tukaani.xz.**
-dontwarn com.github.luben.zstd.**
-dontwarn org.brotli.dec.**
-dontwarn org.objectweb.asm.**
-dontwarn org.osgi.**
-dontwarn java.lang.invoke.**
