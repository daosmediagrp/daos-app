from PIL import Image
import base64, io, pathlib
base = pathlib.Path(__file__).parent

def datauri(path, width):
    im = Image.open(path).convert("RGBA")
    ratio = width / im.width
    im = im.resize((width, int(im.height * ratio)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

tpl = (base / "facebook-index.html").read_text()
tpl = tpl.replace("__CIRCLED__", datauri(base / "assets/daos-circled-d.png", 288))
tpl = tpl.replace("__SCRIPT__", datauri(base / "assets/daos-script.png", 200))
out = base / "index.html"
out.write_text(tpl)
print("wrote", out, out.stat().st_size, "bytes")
