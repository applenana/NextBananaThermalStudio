allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // AGP 8+ 兼容补丁: 给没有声明 namespace 的老插件 (如 flutter_libserialport 0.4.0)
    // 自动注入 namespace, 避免 "Namespace not specified" 配置失败.
    plugins.withId("com.android.library") {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.let { ext ->
            if (ext.namespace.isNullOrEmpty()) {
                val pkg = project.name.replace('-', '_')
                ext.namespace = "com.flutter.plugin.$pkg"
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
