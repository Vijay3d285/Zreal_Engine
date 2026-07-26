def can_build(env, platform):
    # The OIDN `RT` filter final-denoise is a Windows x86_64 editor-time integration for
    # still-image capture. Linking requires the prebuilt OIDN binary distribution placed at
    # thirdparty/oidn (include/ + lib/). We only build the module in the editor on x86_64
    # Windows; other platforms are out of scope for now. Explicitly enable with oidn=yes.
    if platform != "windows":
        return False
    if env["arch"] != "x86_64":
        return False
    if not env.editor_build:
        return False
    return True


def configure(env):
    pass


def get_doc_classes():
    return []


def get_doc_path():
    return "doc_classes"
