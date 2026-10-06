// pfanctl - 松下 CFQV8 ACPI 求值器（支持嵌套 Package / Buffer）
// 用法: echo "<ACPI路径> [argc [a0 a1 a2 a3]]" > /dev/pfanctl
// 读 dmesg 见 "pfanctl: RESULT ..."
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/miscdevice.h>
#include <linux/acpi.h>

static int dump_obj(union acpi_object *o, char *out, int maxlen, int level)
{
	int len = 0, i;
	if (level > 4 || maxlen < 32) return 0;
	switch (o->type) {
	case ACPI_TYPE_INTEGER:
		len = scnprintf(out, maxlen, "%lld", (long long)o->integer.value);
		break;
	case ACPI_TYPE_STRING:
		len = scnprintf(out, maxlen, "\"%s\"", o->string.pointer);
		break;
	case ACPI_TYPE_BUFFER:
		len = scnprintf(out, maxlen, "buf(");
		for (i = 0; i < (int)o->buffer.length && i < 80 && len < maxlen - 4; i++)
			len += scnprintf(out+len, maxlen-len, "%02x", o->buffer.pointer[i]);
		len += scnprintf(out+len, maxlen-len, ")");
		break;
	case ACPI_TYPE_PACKAGE:
		len = scnprintf(out, maxlen, "[");
		for (i = 0; i < (int)o->package.count && i < 48; i++) {
			if (len < maxlen - 128)
				len += dump_obj(&o->package.elements[i], out+len, maxlen-len, level+1);
			if (i < (int)o->package.count - 1 && len < maxlen - 128)
				len += scnprintf(out+len, maxlen-len, ",");
		}
		len += scnprintf(out+len, maxlen-len, "]");
		break;
	default:
		len = scnprintf(out, maxlen, "t%d", o->type);
	}
	return len;
}

static int pfan_eval(const char *path, int argc, long *av)
{
	acpi_handle handle = NULL;
	acpi_status st;
	struct acpi_buffer res;
	struct acpi_object_list arglist;
	union acpi_object objs[4];
	union acpi_object *o;
	char *out;
	int i;

	st = acpi_get_handle(NULL, path, &handle);
	if (ACPI_FAILURE(st)) { pr_err("pfanctl: get_handle(%s)=%x\n", path, st); return -ENODEV; }
	memset(objs, 0, sizeof(objs));
	if (argc > 4) argc = 4;
	for (i = 0; i < argc; i++) { objs[i].type = ACPI_TYPE_INTEGER; objs[i].integer.value = (u64)av[i]; }
	arglist.count = (u32)argc; arglist.pointer = objs;
	res.length = ACPI_ALLOCATE_BUFFER; res.pointer = NULL;
	st = acpi_evaluate_object(handle, NULL, &arglist, &res);
	pr_info("pfanctl: %s argc=%d st=%x len=%u\n", path, argc, st, (unsigned)res.length);
	if (!ACPI_SUCCESS(st) || !res.pointer) { if (res.pointer) kfree(res.pointer); return 0; }

	if (res.length == ACPI_TYPE_INTEGER) {
		pr_info("pfanctl: RESULT int=%lld\n", (long long)*(acpi_integer *)res.pointer);
		kfree(res.pointer); return 0;
	}
	if (res.length == ACPI_ALLOCATE_BUFFER) {
		pr_info("pfanctl: RESULT void\n"); kfree(res.pointer); return 0;
	}
	if (res.length > 8 && res.length <= 65536) {
		o = (union acpi_object *)res.pointer;
		out = kmalloc(8192, GFP_KERNEL);
		if (out) { *out = 0; dump_obj(o, out, 8192, 0); pr_info("pfanctl: RESULT %s\n", out); kfree(out); }
		kfree(res.pointer);
	}
	return 0;
}

static ssize_t pfan_write(struct file *f, const char __user *buf, size_t n, loff_t *p)
{
	char kbuf[512], *p2, *p3;
	long a[4] = {0,0,0,0};
	int argc = 0, i;
	if (n >= sizeof(kbuf)) n = sizeof(kbuf)-1;
	if (copy_from_user(kbuf, buf, n)) return -EFAULT;
	kbuf[n] = 0; strim(kbuf);
	p2 = strchr(kbuf, 0x20);
	if (p2) { *p2 = 0; p2++; argc = (int)simple_strtol(p2, NULL, 0);
		p3 = strchr(p2, 0x20);
		if (p3) { *p3 = 0; p2 = p3 + 1;
			for (i = 0; i < 4 && p2; i++) { a[i] = simple_strtol(p2, &p2, 0);
				if (!p2) break; p2 = strchr(p2, 0x20); if (p2) p2++; } } }
	/* 便捷语法: "ec88 0x76" -> 展开为完整 EC88 调用 */
	if (strncmp(kbuf, "ec88", 4) == 0) {
		char buf2[512];
		const char *reg = kbuf + 4;
		while (*reg == 0x20) reg++;
		scnprintf(buf2, sizeof(buf2),
			"\\_SB.PCI0.LPCB.EC0.EC88 4 181 %s 0 0", reg);
		{
			char *q = strchr(buf2, 0x20);
			long av[4] = {0,0,0,0};
			int na = 0;
			if (q) { *q = 0; q++;
				while (q && na < 4) {
					av[na++] = simple_strtol(q, &q, 0);
					if (!q) break;
					q = strchr(q, 0x20);
					if (q) q++;
				}
			}
			pfan_eval(buf2, na, av);
		}
		return n;
	}
	pfan_eval(kbuf, argc, a);
	return n;
}
static const struct file_operations pfan_fops = { .owner = THIS_MODULE, .write = pfan_write };
static struct miscdevice pfan_misc = { .minor = MISC_DYNAMIC_MINOR, .name = "pfanctl", .fops = &pfan_fops };
static int __init pfan_init(void)
{ int r = misc_register(&pfan_misc); if (r) return r; pr_info("pfanctl: ready\n"); return 0; }
static void __exit pfan_exit(void) { misc_deregister(&pfan_misc); }
module_init(pfan_init); module_exit(pfan_exit);
MODULE_LICENSE("GPL");
