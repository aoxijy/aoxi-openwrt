#!/usr/bin/env python3
"""Keep Lean's Shortcut FE addition compatible with stable sk_buff backports."""
from pathlib import Path


def fix(root: Path):
    patch = root / 'target/linux/generic/hack-6.18/953-net-patch-linux-kernel-to-support-shortcut-fe.patch'
    if not patch.exists():
        return
    text = patch.read_text()
    start = text.index('--- a/include/linux/skbuff.h\n')
    end = text.index('\n--- a/', start + 1)
    section = text[start:end]
    old = '''--- a/include/linux/skbuff.h
+++ b/include/linux/skbuff.h
@@ -1030,6 +1030,9 @@ struct sk_buff {
 \t__u8\t\t\tcsum_not_inet:1;
 #endif
 \t__u8\t\t\tunreadable:1;
+#ifdef CONFIG_SHORTCUT_FE
+\t__u8\t\t\tfast_forwarded:1;
+#endif
 #if defined(CONFIG_NET_SCHED) || defined(CONFIG_NET_XGRESS)
 \t__u16\t\t\ttc_index;\t/* traffic control index */
 #endif'''
    # Keep trailing context: GNU patch otherwise treats this as an EOF hunk.
    # Linux 6.18.58 adds tc_depth between unreadable and tc_index.
    new = old.replace('-1030,6 +1030,9', '-1030,7 +1030,10').replace(
        '\n #if defined(CONFIG_NET_SCHED)', '\n \t__u8\t\t\ttc_depth:2;\n #if defined(CONFIG_NET_SCHED)')
    # Lean now carries the stable tc_depth context itself. Preserve its hunk.
    upstream = '''--- a/include/linux/skbuff.h
+++ b/include/linux/skbuff.h
@@ -1032,6 +1032,9 @@
 #endif
 	__u8			unreadable:1;
 	__u8			tc_depth:2;
+#ifdef CONFIG_SHORTCUT_FE
+	__u8			fast_forwarded:1;
+#endif
 #if defined(CONFIG_NET_SCHED) || defined(CONFIG_NET_XGRESS)
 	__u16			tc_index;	/* traffic control index */
 #endif'''
    if section in (new, upstream):
        return
    if section != old:
        raise RuntimeError('Shortcut FE patch changed upstream; inspect before adapting')
    patch.write_text(text[:start] + new + text[end:])
    print('Adapted Shortcut FE sk_buff context for stable kernel backports')


if __name__ == '__main__':
    fix(Path.cwd())
