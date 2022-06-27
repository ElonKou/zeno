#include <zeno/zeno.h>
#include <zeno/types/PrimitiveObject.h>
#include <zeno/types/PrimitiveUtils.h>
#include <zeno/types/StringObject.h>
#include <zeno/types/NumericObject.h>
#include <zeno/utils/variantswitch.h>
#include <zeno/utils/arrayindex.h>
#include <unordered_map>
#include <functional>

namespace zeno {
namespace {

template <class Cond>
static float tri_intersect(Cond cond, vec3f const &ro, vec3f const &rd,
                           vec3f const &v0, vec3f const &v1, vec3f const &v2) {
        vec3f u = v1 - v0;
        vec3f v = v2 - v0;
        vec3f n = cross(u, v);

        float b = dot(n, rd);
        if (std::abs(b) > 1e-8f) {
            float a = dot(n, v0 - ro);
            float r = a / b;
            if (cond(r)) {  // r > 0
                vec3f ip = ro + r * rd;
                float uu = dot(u, u);
                float uv = dot(u, v);
                float vv = dot(v, v);
                vec3f w = ip - v0;
                float wu = dot(w, u);
                float wv = dot(w, v);
                float d = (uv * uv - uu * vv);
                float s = (uv * wv - vv * wu);
                float t = (uv * wu - uu * wv);
                s = std::copysign(s, d);
                t = std::copysign(t, d);
                d = std::abs(d);
                if (0 <= s && s <= d && 0 <= t && s + t <= d)
                    return r;
            }
    }
    return 0;
}

struct BVH {
    PrimitiveObject const *prim{};

    void build(PrimitiveObject const *prim) {
        this->prim = prim;
    }

    template <class Cond>
    float intersect(Cond cond, vec3f const &ro, vec3f const &rd) {
        for (size_t i = 0; i < prim->tris.size(); i++) {
            auto ind = prim->tris[i];
            auto a = prim->verts[ind[0]];
            auto b = prim->verts[ind[1]];
            auto c = prim->verts[ind[2]];
            float d = tri_intersect(cond, ro, rd, a, b, c);
            if (d != 0)
                return d;
        }
        return 0;
    }
};

struct PrimProject : INode {
    virtual void apply() override {
        auto prim = get_input<PrimitiveObject>("prim");
        auto targetPrim = get_input<PrimitiveObject>("targetPrim");
        auto offset = get_input2<float>("offset");
        auto limit = get_input2<float>("limit");
        auto nrmAttr = get_input2<std::string>("nrmAttr");
        auto allowDir = get_input2<std::string>("allowDir");

        BVH bvh;
        bvh.build(targetPrim.get());
        auto const &nrm = prim->verts.attr<vec3f>(nrmAttr);
        auto comp = enum_variant<std::variant<
            std::greater<float>, std::less<float>, std::not_equal_to<float>
            >>(array_index_safe({"front", "back", "both"},
                                allowDir, "allowDir"));
        std::visit([&] (auto comp) {
            auto cond = [=] (float r) { return comp(r, 0.f); };
            for (size_t i = 0; i < prim->verts.size(); i++) {
                auto ro = prim->verts[i];
                auto rd = normalizeSafe(nrm[i], 1e-6f);
                float t = bvh.intersect(cond, ro, rd);
                if (limit > 0 && std::abs(t) > limit)
                    t = 0;
                t -= offset;
                prim->verts[i] = ro + t * rd;
            }
        }, comp);

        set_output("prim", std::move(prim));
    }
};

ZENDEFNODE(PrimProject, {
    {
    {"PrimitiveObject", "prim"},
    {"PrimitiveObject", "targetPrim"},
    {"string", "nrmAttr", "nrm"},
    {"float", "offset", "0"},
    {"float", "limit", "0"},
    {"enum front back both", "allowDir", "both"},
    //{"bool", "targetPositive", "1"},
    //{"bool", "targetNegitive", "1"},
    },
    {
    {"PrimitiveObject", "prim"},
    },
    {
    },
    {"primitive"},
});

}
}

