const P = require(process.argv[2] || require("path").join(__dirname, "..", "pwa", "receipt-parser.js"));
// helper: lines given as [y, [x, text], [x, text]...]
const mk = (rows) => rows.flatMap(([y, ...parts]) => parts.map(([x, text]) => ({ text, x, y, w: text.length * 12, h: 30 })));
const cats = ["Groceries", "Food & Drink", "Transport", "Health", "Bills & Utilities", "Salary", "Other", "Shopping"];
const ctx = { categories: cats, history: [{ description: "Warung Bu Tini", category: "Food & Drink" }] };
let fail = 0;
const check = (name, got, want) => {
  const bad = Object.keys(want).filter((k) => JSON.stringify(got?.[k]) !== JSON.stringify(want[k]));
  if (bad.length) { fail++; console.log("FAIL", name, bad.map((k) => `${k}: got ${JSON.stringify(got?.[k])} want ${JSON.stringify(want[k])}`).join("; ")); }
  else console.log("ok  ", name);
};

// 1. real Alfamart reading (from the browser prototype)
const alfa = `187,353,396,35 | ALFAMART ARTHA GADING N / 081294665105
224,385,309,36 | PT.SUMBER ALFARIA TRIJAYA, TBK
172,452,411,35 | ALFA TOWER LT.12, ALAM SUTERA, TANGERANG
233,489,287,31 | NPWP : 01.336.238.9-054.000
173,521,420,31 | KOMP. RUKO ARTHA GADING NIAGA KELAPA GAD
169,585,424,35 | Bon JA19-789-17015H94 Kasir : MARDIYAN
169,652,170,31 | MARLBORO LGT 20
376,652,113,35 | 1 44,900
515,656,78,31 | 44,900
167,716,120,35 | Total ltem
308,717,44,38 | 1
515,721,82,36 | 44,900
164,751,68,36 | Tunai
515,756,82,36 | 44,900
164,785,108,35 | Kembalian
560,788,45,43 | 0
159,816,88,41 | PPN (
321,816,50,47 | 0)
161,889,424,42 | Tgl. 17-01-2024 15:31:44 V.2023.11.0
263,963,222,30 | Kritik&Saran:1500959
263,995,224,34 | SMS/WA:081110640888`.split("\n").map((l) => { const [b, t] = l.split(" | "); const [x, y, w, h] = b.split(",").map(Number); return { x, y, w, h, text: t }; });
check("alfamart real", P.parse("receipt", alfa, ctx)[0], { amount: 44900, date: "2024-01-17", description: "ALFAMART ARTHA GADING N", category: "Groceries", type: "expense" });

// 2. synthetic Indomaret with cash and change
check("indomaret", P.parse("receipt", mk([
  [40, [30, "INDOMARET KEMANG"]], [90, [30, "Jl. Kemang Raya 12"]], [140, [30, "10/11/2026 14:22"]],
  [190, [30, "Indomie Goreng x3"], [350, "10.500"]], [240, [30, "Aqua 600ml x2"], [350, "8.000"]], [290, [30, "Roti Tawar"], [350, "18.000"]],
  [380, [30, "TOTAL"], [350, "36.500"]], [430, [30, "TUNAI"], [350, "50.000"]], [480, [30, "KEMBALI"], [350, "13.500"]],
]), ctx)[0], { amount: 36500, date: "2026-11-10", description: "INDOMARET KEMANG", category: "Groceries" });

// 3. restaurant: subtotal, service, tax, grand total, paid by card
check("resto grand total", P.parse("receipt", mk([
  [40, [30, "KOPI KENANGAN - SUDIRMAN"]], [90, [30, "Telp 021-5551234"]], [140, [30, "05 Nov 2026  19:02"]],
  [190, [30, "2 Kopi Susu"], [350, "44.000"]], [240, [30, "1 Croissant"], [350, "28.000"]],
  [300, [30, "Subtotal"], [350, "72.000"]], [340, [30, "Service 5%"], [350, "3.600"]], [380, [30, "PB1 10%"], [350, "7.560"]],
  [430, [30, "Grand Total"], [350, "Rp 83.160"]], [480, [30, "Debit BCA"], [350, "83.160"]],
]), ctx)[0], { amount: 83160, date: "2026-11-05", description: "KOPI KENANGAN - SUDIRMAN", category: "Food & Drink" });

// 4. no "total" word: paid minus change
check("paid minus change", P.parse("receipt", mk([
  [40, [30, "WARUNG BU TINI"]], [140, [30, "Nasi Ayam"], [350, "25.000"]], [190, [30, "Es Teh"], [350, "5.000"]],
  [300, [30, "Tunai"], [350, "50.000"]], [350, [30, "Kembali"], [350, "20.000"]],
]), ctx)[0], { amount: 30000, description: "WARUNG BU TINI", category: "Food & Drink", date: "" });

// 5. subtotal then total with discount line between; decimals ",00"
check("discount + decimals", P.parse("receipt", mk([
  [40, [30, "APOTEK K-24 CILANDAK"]], [90, [30, "2026-10-28 09:15"]],
  [150, [30, "Paracetamol"], [350, "12.000,00"]], [200, [30, "Vitamin C"], [350, "45.000,00"]],
  [260, [30, "SUBTOTAL"], [350, "57.000,00"]], [300, [30, "DISKON MEMBER"], [350, "5.000,00"]], [340, [30, "TOTAL"], [350, "52.000,00"]],
]), ctx)[0], { amount: 52000, date: "2026-10-28", category: "Health" });

// 6. fuel receipt: no total keyword, no cash rows -> largest
check("largest fallback", P.parse("receipt", mk([
  [40, [30, "SPBU PERTAMINA 34.12345"]], [90, [30, "12-11-2026"]],
  [150, [30, "Pertamax"], [350, "13.500"]], [200, [30, "Liter 14,81"]], [250, [30, "Rp"], [350, "200.000"]],
]), ctx)[0], { amount: 200000, date: "2026-11-12", category: "Transport" });

// 7. payslip
check("payslip", P.parse("payslip", mk([
  [40, [30, "PT MAJU JAYA - SLIP GAJI"]], [90, [30, "Periode: Oktober 2026"]],
  [150, [30, "Gaji Pokok"], [350, "8.000.000"]], [200, [30, "Tunjangan"], [350, "1.500.000"]],
  [250, [30, "Potongan BPJS"], [350, "-320.000"]], [300, [30, "PPh 21"], [350, "-410.000"]],
  [360, [30, "TAKE HOME PAY"], [350, "8.770.000"]],
]), ctx)[0], { amount: 8770000, type: "income", category: "Salary", date: "2026-10-31", description: "PT MAJU JAYA" });

// 8. history screenshot
const hist = P.parse("history", mk([
  [40, [30, "MUTASI REKENING - NOV 2026"]],
  [100, [30, "12/11"], [120, "GOPAY TOPUP"], [380, "-100.000"], [520, "DB"]],
  [150, [30, "12/11"], [120, "TRANSFER DARI BUDI"], [380, "+750.000"], [520, "CR"]],
  [200, [30, "13/11"], [120, "PLN TOKEN LISTRIK"], [380, "-200.000"], [520, "DB"]],
  [250, [30, "14/11"], [120, "GRAB*RIDE"], [380, "-23.500"], [520, "DB"]],
  [300, [30, "SALDO AKHIR"], [380, "5.426.500"]],
]), ctx);
check("history count", { n: hist.length }, { n: 4 });
check("history row 1", hist[0], { type: "expense", amount: 100000, date: "2026-11-12", description: "GOPAY TOPUP" });
check("history row 2", hist[1], { type: "income", amount: 750000, description: "TRANSFER DARI BUDI" });
check("history row 3", hist[2], { type: "expense", amount: 200000, category: "Bills & Utilities", date: "2026-11-13" });
check("history row 4", hist[3], { type: "expense", amount: 23500, category: "Transport" });

// 9. history with date headings and balance column
const hist2 = P.parse("history", mk([
  [40, [30, "14 Nov 2026"]],
  [90, [30, "Indomaret Kemang"], [380, "-Rp45.300"]],
  [140, [30, "Gaji PT Maju"], [380, "+Rp8.770.000"]],
  [200, [30, "13 Nov 2026"]],
  [250, [30, "Bayar Shopee"], [380, "-Rp120.000"]],
]), ctx);
check("history2 count", { n: hist2.length }, { n: 3 });
check("history2 row 1", hist2[0], { type: "expense", amount: 45300, date: "2026-11-14", category: "Groceries" });
check("history2 row 2", hist2[1], { type: "income", amount: 8770000, date: "2026-11-14" });
check("history2 row 3", hist2[2], { type: "expense", amount: 120000, date: "2026-11-13" });

// 10. nothing readable
check("empty", { n: P.parse("receipt", mk([[40, [30, "TERIMA KASIH"]]]), ctx).length }, { n: 0 });
console.log(fail ? `${fail} FAILED` : "ALL PASSED");
