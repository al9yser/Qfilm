#!/usr/bin/env python3
"""يبحث عن أسرع بروكسي HTTP يعمل مع الموقع من قوائم GitHub العامة.

التشغيل (على الكمبيوتر أو في Termux على الجوال، ومعك نفس شبكتك):
    python3 find_proxy.py                # يجرّب القوائم المدمجة
    python3 find_proxy.py --top 5        # يعرض أفضل 5
    python3 find_proxy.py --url https://.../list.txt   # قائمة إضافية

يستخدم مكتبات بايثون القياسية فقط. النتيجة: عناوين ip:port مرتبة حسب السرعة.
تحذير: البروكسيات المجانية غير آمنة وتتوقف بسرعة. لا تدخل بها كلمات مرور.
"""
import argparse, re, time, urllib.request, concurrent.futures as cf

SITE = "http://a.qfilm.tv"
MARKER = "qfilm"  # كلمة يجب أن تظهر في الصفحة الحقيقية
SOURCES = [
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt",
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.txt",
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
]
ADDR = re.compile(r"(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})")


def fetch_list(url):
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            text = r.read().decode("utf-8", "ignore")
        return {f"{ip}:{port}" for ip, port in ADDR.findall(text)}
    except Exception as e:
        print(f"  تعذر تحميل {url}: {e}")
        return set()


def test(addr, timeout):
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": f"http://{addr}"})
    )
    t = time.time()
    try:
        with opener.open(SITE, timeout=timeout) as r:
            body = r.read(200_000).decode("utf-8", "ignore").lower()
            if r.status == 200 and MARKER in body:
                return addr, time.time() - t
    except Exception:
        pass
    return addr, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--timeout", type=float, default=6)
    ap.add_argument("--max", type=int, default=600, help="أقصى عدد عناوين للفحص")
    ap.add_argument("--url", action="append", default=[])
    a = ap.parse_args()

    pool = set()
    for u in SOURCES + a.url:
        got = fetch_list(u)
        print(f"{len(got):6d} عنوان من {u}")
        pool |= got
    pool = list(pool)[: a.max]
    print(f"فحص {len(pool)} عنوان...")

    ok = []
    with cf.ThreadPoolExecutor(max_workers=60) as ex:
        for addr, dt in ex.map(lambda p: test(p, a.timeout), pool):
            if dt is not None:
                ok.append((dt, addr))
    ok.sort()
    if not ok:
        print("لا يوجد بروكسي صالح الآن. أعد المحاولة بعد قليل.")
        return
    print("\nالأسرع (الثواني : العنوان):")
    for dt, addr in ok[: a.top]:
        print(f"  {dt:5.2f}s  {addr}")
    print("\nضع أحدها في Qfilm: القائمة ← إعداد خادم VPN. ")


if __name__ == "__main__":
    main()
