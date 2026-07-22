package config

import "strings"

// provinceByCode maps a lowercase province short code (or the Chinese name
// itself) to the canonical Chinese province name, mirroring province_from_code
// in the original script.
var provinceByCode = map[string]string{
	"he": "河北", "河北": "河北",
	"sx": "山西", "山西": "山西",
	"ln": "辽宁", "辽宁": "辽宁",
	"jl": "吉林", "吉林": "吉林",
	"hl": "黑龙江", "黑龙江": "黑龙江",
	"js": "江苏", "江苏": "江苏",
	"zj": "浙江", "浙江": "浙江",
	"ah": "安徽", "安徽": "安徽",
	"fj": "福建", "福建": "福建",
	"jx": "江西", "江西": "江西",
	"sd": "山东", "山东": "山东",
	"ha": "河南", "河南": "河南",
	"hb": "湖北", "湖北": "湖北",
	"hn": "湖南", "湖南": "湖南",
	"gd": "广东", "广东": "广东",
	"hi": "海南", "海南": "海南",
	"sc": "四川", "四川": "四川",
	"gz": "贵州", "贵州": "贵州",
	"yn": "云南", "云南": "云南",
	"sn": "陕西", "陕西": "陕西",
	"gs": "甘肃", "甘肃": "甘肃",
	"qh": "青海", "青海": "青海",
	"nm": "内蒙古", "内蒙古": "内蒙古",
	"gx": "广西", "广西": "广西",
	"xz": "西藏", "西藏": "西藏",
	"nx": "宁夏", "宁夏": "宁夏",
	"xj": "新疆", "新疆": "新疆",
	"bj": "北京", "北京": "北京",
	"tj": "天津", "天津": "天津",
	"sh": "上海", "上海": "上海",
	"cq": "重庆", "重庆": "重庆",
}

// ProvinceFromCode resolves a province short code or Chinese name to the
// canonical province name. The leading '-' of shorthand flags (e.g. "-bj") is
// stripped and ASCII is lowercased before lookup. ok is false when unknown.
func ProvinceFromCode(code string) (string, bool) {
	code = strings.ToLower(code)
	code = strings.TrimPrefix(code, "-")
	name, ok := provinceByCode[code]
	return name, ok
}
