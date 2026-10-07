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

/* 参数解析。坏 token 返回 -EINVAL，绝不静默变成 0。
 *
 * 0 表示停转，而 "0" 与"解析失败"在旧实现里是同一个值：
 *   - base 0 下 "080" 被读成八进制，'8' 不是八进制数字 → 就地截断成 0；
 *   - 更要命的是 simple_strtol 对非数字（"abc"、""、"-1"）一律返回 0 且不报错，
 *     于是 "ec88 zz" 之类会把 0 当参数发进 ACPI（复审 F5）。
 * 分隔符必须是空格或串尾：只吃一半（"42abc"）等于丢掉后缀，档位照样算错。
 *
 * base：内核 simple_strtol 的 base=0 只认 0x/0X，【没有 0b/0B】——
 * 之前注释声称 b/B 也走 base 0 是错的（"0b101" 只会解析出 0）。
 * 十进制是缺省，EC88 的 0x79 / 0x02 走 base 0 分支。 */
static long pfan_parse(const char *s, char **endp)
{
	char *end = NULL;
	long v;
	int base = 10;

	/* 只接受以数字开头：非数字开头（空串、字母、负号）直接判非法。
	 * 档位与 EC 参数都是非负数，负号没有合法用途。 */
	if (!s || s[0] < '0' || s[0] > '9')
		return -EINVAL;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		base = 0;
	v = simple_strtol(s, &end, base);
	if (!end || end == s)
		return -EINVAL;
	if (*end != '\0' && *end != ' ')
		return -EINVAL;		/* 半截 token：静默丢后缀 = 算错档 */
	if (endp)
		*endp = (char *)end;
	return v;
}

static int pfan_eval(const char *path, int argc, long *av)
{
	acpi_handle handle = NULL;
	acpi_status st;
	struct acpi_buffer res;
	struct acpi_object_list arglist;
	union acpi_object objs[4];
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
	/* ⑭ 这条是 dmesg 里绝大多数噪音的来源（每次 ACPI 调用一行）。
	 * 消费者只依赖下面的 RESULT 行，所以降为 pr_debug。 */
	pr_debug("pfanctl: %s argc=%d st=%x len=%u\n", path, argc, st, (unsigned)res.length);
	if (!ACPI_SUCCESS(st) || !res.pointer) { if (res.pointer) kfree(res.pointer); return 0; }

	/* res.length 是【字节长度】，不是对象类型。旧代码曾拿它与 ACPI_TYPE_INTEGER /
	 * ACPI_ALLOCATE_BUFFER 比较 —— 求值成功后这两个分支永远不会进入（死分支），
	 * 而且它们之外的 kfree 也在分支里，小结果会既不打印也不释放。
	 * 现在统一走 dump_obj，释放放到分支之外。 */
	if (res.length > 8 && res.length <= 65536) {
		out = kmalloc(8192, GFP_KERNEL);
		if (out) {
			*out = 0;
			dump_obj((union acpi_object *)res.pointer, out, 8192, 0);
			pr_info("pfanctl: RESULT %s\n", out);
			kfree(out);
		}
	}
	kfree(res.pointer);
	return 0;
}

static ssize_t pfan_write(struct file *f, const char __user *buf, size_t n, loff_t *p)
{
	char kbuf[512], *p2, *p3;
	long a[4] = {0,0,0,0};
	long err;
	int argc = 0, i;
	if (n >= sizeof(kbuf)) n = sizeof(kbuf)-1;
	if (copy_from_user(kbuf, buf, n)) return -EFAULT;
	kbuf[n] = 0; strim(kbuf);
	p2 = strchr(kbuf, 0x20);
	if (p2) { *p2 = 0; p2++;
		err = pfan_parse(p2, NULL);
		if (err < 0) return err;	/* -EINVAL：坏 token 绝不发进 ACPI */
		argc = (int)err;
		p3 = strchr(p2, 0x20);
		if (p3) { *p3 = 0; p2 = p3 + 1;
			for (i = 0; i < 4 && p2; i++) {
				err = pfan_parse(p2, &p2);
				if (err < 0) return err;
				a[i] = err;
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
					err = pfan_parse(q, &q);
					if (err < 0) return err;
					av[na++] = err;
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
