function u32(x) { x = x % 4294967296; if (x < 0) x += 4294967296; return x }
BEGIN {
    ALPHA = "LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"
    for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
    # 关键：与门户 JS 一致，key 用的是 token 字符串本身的字符（十六进制字符的 ASCII 码），
    # 不是把 hex 解码成字节。这一点搞错，密文会完全不同。
    tl = length(TOKEN)
    kc = 0
    for (i = 1; i <= tl; i += 4) {
        t = 0
        for (j = 0; j < 4 && i + j <= tl; j++) t += ORD[substr(TOKEN, i + j, 1)] * 2 ^ (8 * j)
        K[kc++] = t
    }
    while (kc < 4) K[kc++] = 0
    nb = 0
}
{ for (i = 1; i <= NF; i++) B[nb++] = $i + 0 }
END {
    if (nb == 0) { printf "\n"; exit }
    # 字节 -> 小端 32 位字，末尾补长度
    vc = 0
    for (i = 0; i < nb; i += 4) {
        t = 0
        for (j = 0; j < 4; j++) if (i + j < nb) t += B[i + j] * 2 ^ (8 * j)
        V[vc++] = t
    }
    V[vc++] = nb
    n = vc - 1
    z = V[n]; sum = 0
    q = 6 + int(52 / (n + 1))
    while (q > 0) {
        sum = u32(sum + 2654435769)          # 0x9E3779B9
        e = int(sum / 4) % 4
        for (p = 0; p <= n; p++) {
            y = (p == n) ? V[0] : V[p + 1]
            m = xor(rshift(z, 5), u32(lshift(y, 2)))
            m = u32(m + xor(xor(rshift(y, 3), u32(lshift(z, 4))), xor(sum, y)))
            m = u32(m + xor(K[xor(p % 4, e)], z))
            V[p] = u32(V[p] + m)
            z = V[p]
        }
        q--
    }
    # 字 -> 字节
    ob = 0
    for (p = 0; p <= n; p++) {
        w = V[p]
        for (j = 0; j < 4; j++) { OB[ob++] = w % 256; w = int(w / 256) }
    }
    # 乱序 base64
    for (o = 0; o < ob; o += 3) {
        p2 = OB[o]
        p1 = (o + 1 < ob) ? OB[o + 1] : 0
        p0 = (o + 2 < ob) ? OB[o + 2] : 0
        h = p2 * 65536 + p1 * 256 + p0
        for (i = 0; i < 4; i++) {
            if (o * 8 + i * 6 > ob * 8) printf "="
            else printf "%s", substr(ALPHA, int(h / 2 ^ (6 * (3 - i))) % 64 + 1, 1)
        }
    }
    printf "\n"
}
