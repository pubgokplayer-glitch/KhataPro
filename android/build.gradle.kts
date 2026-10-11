allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    tasks.configureEach {
        if (name.contains("compile") && name.contains("Kotlin")) {
            try {
                val getCompilerOptions = javaClass.getMethod("getCompilerOptions")
                val compilerOptions = getCompilerOptions.invoke(this)
                val getFreeCompilerArgs = compilerOptions.javaClass.getMethod("getFreeCompilerArgs")
                val freeCompilerArgsProp = getFreeCompilerArgs.invoke(compilerOptions)
                val addMethod = freeCompilerArgsProp.javaClass.getMethod("add", Object::class.java)
                addMethod.invoke(freeCompilerArgsProp, "-Xskip-metadata-version-check")
            } catch (_: Throwable) {
                try {
                    val getKotlinOptions = javaClass.getMethod("getKotlinOptions")
                    val kotlinOptions = getKotlinOptions.invoke(this)
                    val getFreeCompilerArgs = kotlinOptions.javaClass.getMethod("getFreeCompilerArgs")
                    val setFreeCompilerArgs = kotlinOptions.javaClass.getMethod("setFreeCompilerArgs", List::class.java)
                    @Suppress("UNCHECKED_CAST")
                    val args = getFreeCompilerArgs.invoke(kotlinOptions) as? List<String> ?: emptyList()
                    if (!args.contains("-Xskip-metadata-version-check")) {
                        setFreeCompilerArgs.invoke(kotlinOptions, args + "-Xskip-metadata-version-check")
                    }
                } catch (_: Throwable) {}
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
