#include "Structures.hpp"
#include "zensim/Logger.hpp"
#include "zensim/cuda/execution/ExecutionPolicy.cuh"
#include "zensim/omp/execution/ExecutionPolicy.hpp"
#include "zensim/io/MeshIO.hpp"
#include "zensim/math/bit/Bits.h"
#include "zensim/types/Property.h"
#include <atomic>
#include <zeno/VDBGrid.h>
#include <zeno/types/ListObject.h>
#include <zeno/types/NumericObject.h>
#include <zeno/types/PrimitiveObject.h>
#include <zeno/types/StringObject.h>

#include "constraint_function_kernel/constraint.cuh"
#include "../geometry/kernel/tiled_vector_ops.hpp"
#include "../geometry/kernel/topology.hpp"
#include "../geometry/kernel/geo_math.hpp"
#include "../geometry/kernel/bary_centric_weights.hpp"
// #include "../fem/collision_energy/evaluate_collision.hpp"
#include "constraint_function_kernel/constraint_types.hpp"

namespace zeno {
// we only need to record the topo here
// serve triangulate mesh or strands only currently
struct MakeSurfaceConstraintTopology : INode {

    using bvh_t = ZenoLinearBvh::lbvh_t;
    using bv_t = bvh_t::Box;
    using dtiles_t = zs::TileVector<T,32>;

    template <typename TileVecT>
    void buildBvh(zs::CudaExecutionPolicy &pol, 
            TileVecT &verts, 
            const zs::SmallString& srcTag,
            const zs::SmallString& dstTag,
            const zs::SmallString& pscaleTag,
                bvh_t &bvh) {
        using namespace zs;
        constexpr auto space = execspace_e::cuda;
        Vector<bv_t> bvs{verts.get_allocator(), verts.size()};
        pol(range(verts.size()),
            [verts = proxy<space>({}, verts),
             bvs = proxy<space>(bvs),
             pscaleTag,srcTag,dstTag] ZS_LAMBDA(int vi) mutable {
                auto src = verts.template pack<3>(srcTag, vi);
                auto dst = verts.template pack<3>(dstTag, vi);
                auto pscale = verts(pscaleTag,vi);

                bv_t bv{src,dst};
                bv._min -= pscale;
                bv._max += pscale;
                bvs[vi] = bv;
            });
        bvh.build(pol, bvs);
    }

    virtual void apply() override {
        using namespace zs;
        using namespace PBD_CONSTRAINT;

        using vec3 = zs::vec<float,3>;
        using vec4 = zs::vec<float,4>;
        using vec2i = zs::vec<int,2>;
        using vec3i = zs::vec<int,3>;
        using vec4i = zs::vec<int,4>;
        using mat4 = zs::vec<int,4,4>;

        constexpr auto space = execspace_e::cuda;
        auto cudaPol = zs::cuda_exec();

        auto source = get_input<ZenoParticles>("source");
        auto constraint = std::make_shared<ZenoParticles>();

        auto type = get_input2<std::string>("topo_type");

        if(source->category != ZenoParticles::surface)
            throw std::runtime_error("Try adding Constraint topology to non-surface ZenoParticles");

        auto& verts = source->getParticles();
        const auto& quads = source->getQuadraturePoints();

        auto uniform_stiffness = get_input2<float>("stiffness");

        zs::Vector<float> colors{quads.get_allocator(),0};
        zs::Vector<int> reordered_map{quads.get_allocator(),0};
        zs::Vector<int> color_offset{quads.get_allocator(),0};

        constraint->sprayedOffset = 0;
        constraint->elements = typename ZenoParticles::particles_t({{"stiffness",1},{"lambda",1},{"tclr",1}}, 0, zs::memsrc_e::device,0);
        auto &eles = constraint->getQuadraturePoints();
        constraint->setMeta(CONSTRAINT_TARGET,source.get());

        if(type == "stretch") {
            constraint->setMeta(CONSTRAINT_KEY,category_c::edge_length_constraint);
            auto quads_vec = tilevec_topo_to_zsvec_topo(cudaPol,quads,wrapv<3>{});
            zs::Vector<zs::vec<int,2>> edge_topos{quads.get_allocator(),0};
            retrieve_edges_topology(cudaPol,quads_vec,edge_topos);
            eles.resize(edge_topos.size());

            topological_coloring(cudaPol,edge_topos,colors);
			sort_topology_by_coloring_tag(cudaPol,colors,reordered_map,color_offset);
            // std::cout << "quads.size() = " << quads.size() << "\t" << "edge_topos.size() = " << edge_topos.size() << std::endl;
            eles.append_channels(cudaPol,{{"inds",2},{"r",1}});

            auto rest_scale = get_input2<float>("rest_scale");

            cudaPol(zs::range(eles.size()),[
                verts = proxy<space>({},verts),
                eles = proxy<space>({},eles),
                reordered_map = proxy<space>(reordered_map),
                uniform_stiffness = uniform_stiffness,
                colors = proxy<space>(colors),
                rest_scale = rest_scale,
                edge_topos = proxy<space>(edge_topos)] ZS_LAMBDA(int oei) mutable {
                    auto ei = reordered_map[oei];
                    eles.tuple(dim_c<2>,"inds",oei) = edge_topos[ei].reinterpret_bits(float_c);
                    vec3 x[2] = {};
                    for(int i = 0;i != 2;++i)
                        x[i] = verts.pack(dim_c<3>,"x",edge_topos[ei][i]);
                    eles("r",oei) = (x[0] - x[1]).norm() * rest_scale;
            });            

        }
        if(type == "volume_pin") {
            constexpr auto eps = 1e-6;
            constraint->setMeta(CONSTRAINT_KEY,category_c::volume_pin_constraint);

            auto volume = get_input<ZenoParticles>("target");
            const auto& kverts = volume->getParticles();
            const auto& ktets = volume->getQuadraturePoints();

            constraint->setMeta(CONSTRAINT_TARGET,volume.get());

            auto pin_group_name = get_input2<std::string>("pin_point_group_name");
            auto binder_max_length = get_input2<float>("binder_max_length");

            zs::Vector<zs::vec<int,1>> point_topos{quads.get_allocator(),0};
            if(verts.hasProperty(pin_group_name)) {
                std::cout << "binder name : " << pin_group_name << std::endl;
                zs::bht<int,1,int> pin_point_set{verts.get_allocator(),verts.size()};
                pin_point_set.reset(cudaPol,true);

                cudaPol(zs::range(verts.size()),[
                    verts = proxy<space>({},verts),
                    eps = eps,
                    gname = zs::SmallString(pin_group_name),
                    pin_point_set = proxy<space>(pin_point_set)] ZS_LAMBDA(int vi) mutable {
                        auto gtag = verts(gname,vi);
                        if(gtag > eps)
                            pin_point_set.insert(vi);
                });
                point_topos.resize(pin_point_set.size());
                cudaPol(zip(zs::range(pin_point_set.size()),pin_point_set._activeKeys),[
                    point_topos = proxy<space>(point_topos)] ZS_LAMBDA(auto id,const auto& pvec) mutable {
                        point_topos[id] = pvec[0];
                });
            }else {
                point_topos.resize(verts.size());
                cudaPol(zip(zs::range(point_topos.size()),point_topos),[] ZS_LAMBDA(const auto& id,auto& pi) mutable {pi = id;});
            }
            std::cout << "nm binder point : " << point_topos.size() << std::endl;
            topological_coloring(cudaPol,point_topos,colors,true);
			sort_topology_by_coloring_tag(cudaPol,colors,reordered_map,color_offset);
            
            eles.append_channels(cudaPol,{{"inds",2},{"bary",4}});
            eles.resize(point_topos.size());
            
            auto thickness = binder_max_length / (T)2.0;

            auto ktetBvh = bvh_t{};
            auto ktetBvs = retrieve_bounding_volumes(cudaPol,kverts,ktets,wrapv<4>{},thickness,"x");
            ktetBvh.build(cudaPol,ktetBvs);
            
            cudaPol(zs::range(point_topos.size()),[
                point_topos = proxy<space>(point_topos),
                reordered_map = proxy<space>(reordered_map),
                verts = proxy<space>({},verts),
                ktetBvh = proxy<space>(ktetBvh),
                thickness = thickness,
                eles = proxy<space>({},eles),
                kverts = proxy<space>({},kverts),
                ktets = proxy<space>({},ktets)] ZS_LAMBDA(int oei) mutable {
                    auto ei = reordered_map[oei];
                    auto pi = point_topos[ei][0];
                    auto p = verts.pack(dim_c<3>,"x",pi);
                    auto bv = bv_t{get_bounding_box(p - thickness,p + thickness)};

                    bool found = false;
                    int embed_kti = -1;
                    vec4 bary{};
                    auto find_embeded_tet = [&](int kti) {
                        if(found == true)
                            return;
                        auto inds = ktets.pack(dim_c<4>,"inds",kti,int_c);
                        vec3 ktps[4] = {};
                        for(int i = 0;i != 4;++i)
                            ktps[i] = kverts.pack(dim_c<3>,"x",inds[i]);
                        auto ws = compute_barycentric_weights(p,ktps[0],ktps[1],ktps[2],ktps[3]);

                        T epsilon = zs::limits<float>::epsilon();
                        if(ws[0] > epsilon && ws[1] > epsilon && ws[2] > epsilon && ws[3] > epsilon){
                            embed_kti = kti;
                            bary = ws;
                            found = true;
                            return;
                        }                        
                    };  
                    ktetBvh.iter_neighbors(bv,find_embeded_tet);
                    if(embed_kti >= 0)
                        verts("minv",pi) = 0;
                    eles.tuple(dim_c<2>,"inds",oei) = vec2i{pi,embed_kti}.reinterpret_bits(float_c);
                    eles.tuple(dim_c<4>,"bary",oei) = bary;
            });
        }

        if(type == "point_triangle_pin") {
            constexpr auto eps = 1e-6;
            constraint->setMeta(CONSTRAINT_KEY,category_c::pt_pin_constraint);

            auto target = get_input<ZenoParticles>("target");
            const auto& kverts = target->getParticles();
            const auto& ktris = target->getQuadraturePoints();

            constraint->setMeta(CONSTRAINT_TARGET,target.get());

            auto pin_point_group_name = get_input2<std::string>("pin_point_group_name");
            auto binder_max_length = get_input2<float>("binder_max_length");
            // we might further need a pin_triangle_group_name
            zs::bht<int,1,int> pin_point_set{verts.get_allocator(),verts.size()};
            pin_point_set.reset(cudaPol,true);

            cudaPol(zs::range(verts.size()),[
                verts = proxy<space>({},verts),
                eps = eps,
                gname = zs::SmallString(pin_point_group_name),
                pin_point_set = proxy<space>(pin_point_set)] ZS_LAMBDA(int vi) mutable {
                    auto gtag = verts(gname,vi);
                    if(gtag > eps)
                        pin_point_set.insert(vi);
            });
            zs::Vector<zs::vec<int,1>> point_topos{quads.get_allocator(),pin_point_set.size()};
            cudaPol(zip(zs::range(pin_point_set.size()),pin_point_set._activeKeys),[
                point_topos = proxy<space>(point_topos)] ZS_LAMBDA(auto id,const auto& pvec) mutable {
                    point_topos[id] = pvec[0];
            });

            std::cout << "binder name : " << pin_point_group_name << std::endl;
            std::cout << "nm binder point : " << point_topos.size() << std::endl;
            topological_coloring(cudaPol,point_topos,colors,true);
			sort_topology_by_coloring_tag(cudaPol,colors,reordered_map,color_offset);

            eles.append_channels(cudaPol,{{"inds",2},{"bary",3},{"rd",1}});
            eles.resize(point_topos.size());  

            auto ktriBvh = bvh_t{};
            auto thickness = binder_max_length / (T)2.0;

            auto ktriBvs = retrieve_bounding_volumes(cudaPol,kverts,ktris,wrapv<3>{},thickness,"x");
            ktriBvh.build(cudaPol,ktriBvs);

            cudaPol(zs::range(point_topos.size()),[
                verts = proxy<space>({},verts),
                point_topos = proxy<space>(point_topos),
                kverts = proxy<space>({},kverts),
                ktris = proxy<space>({},ktris),
                thickness = thickness,
                eles = proxy<space>({},eles),
                ktriBvh = proxy<space>(ktriBvh),
                reordered_map = proxy<space>(reordered_map),
                quads = proxy<space>({},quads)] ZS_LAMBDA(auto oei) mutable {
                    auto ei = reordered_map[oei];
                    auto pi = point_topos[ei][0];
                    auto p = verts.pack(dim_c<3>,"x",pi);
                    auto bv = bv_t{get_bounding_box(p - thickness,p + thickness)};

                    int min_kti = -1;
                    T min_dist = std::numeric_limits<float>::max();
                    vec3 min_bary_centric{};
                    auto find_closest_triangles = [&](int kti) {
                        // printf("check binder pair[%d %d]\n",pi,kti);
                        auto ktri = ktris.pack(dim_c<3>,"inds",kti,int_c);
                        vec3 ts[3] = {};
                        for(int i = 0;i != 3;++i)
                            ts[i] = kverts.pack(dim_c<3>,"x",ktri[i]);

                        vec3 bary_centric{};
                        auto pt_dist = LSL_GEO::pointTriangleDistance(ts[0],ts[1],ts[2],p,bary_centric);  
                        for(int i = 0;i != 3;++i)
                            bary_centric[i] = bary_centric[i] < 0 ? 0 : bary_centric[i];
                        // if(pt_dist > thickness * 2)
                        //     return;
                        
                        auto bary_sum = zs::abs(bary_centric[0]) + zs::abs(bary_centric[1]) + zs::abs(bary_centric[2]);
                        bary_centric /= bary_sum;
                        // if(bary_sum > 1.0 + eps * 100)
                        //     return;

                        if(pt_dist < min_dist) {
                            min_dist = pt_dist;
                            min_kti = kti;
                            min_bary_centric = bary_centric;
                        }
                    };
                    ktriBvh.iter_neighbors(bv,find_closest_triangles);

                    if(min_kti >= 0) {
                        auto ktri = ktris.pack(dim_c<3>,"inds",min_kti,int_c);
                        vec3 kps[3] = {};
                        for(int i = 0;i != 3;++i)
                            kps[i] = kverts.pack(dim_c<3>,"x",ktri[i]);
                        auto knrm = LSL_GEO::facet_normal(kps[0],kps[1],kps[2]);
                        auto seg = p - kps[0];
                        if(seg.dot(knrm) < 0)
                            min_dist *= -1;
                        verts("minv",pi) = 0;
                    }

                    eles.tuple(dim_c<2>,"inds",oei) = vec2i{pi,min_kti}.reinterpret_bits(float_c);
                    eles.tuple(dim_c<3>,"bary",oei) = min_bary_centric;
                    eles("rd",oei) = min_dist;
            });
        }

        // angle on (p2, p3) between triangles (p0, p2, p3) and (p1, p3, p2)
        if(type == "bending") {
            constraint->setMeta(CONSTRAINT_KEY,category_c::isometric_bending_constraint);
            // constraint->category = ZenoParticles::tri_bending_spring;
            // constraint->sprayedOffset = 0;

            const auto& halfedges = (*source)[ZenoParticles::s_surfHalfEdgeTag];

            zs::Vector<zs::vec<int,4>> bd_topos{quads.get_allocator(),0};
            retrieve_tri_bending_topology(cudaPol,quads,halfedges,bd_topos);

            eles.resize(bd_topos.size());

            topological_coloring(cudaPol,bd_topos,colors);
			sort_topology_by_coloring_tag(cudaPol,colors,reordered_map,color_offset);
            // std::cout << "quads.size() = " << quads.size() << "\t" << "edge_topos.size() = " << edge_topos.size() << std::endl;

            eles.append_channels(cudaPol,{{"inds",4},{"Q",4 * 4},{"C0",1}});

            // std::cout << "halfedges.size() = " << halfedges.size() << "\t" << "bd_topos.size() = " << bd_topos.size() << std::endl;

            cudaPol(zs::range(eles.size()),[
                eles = proxy<space>({},eles),
                bd_topos = proxy<space>(bd_topos),
                reordered_map = proxy<space>(reordered_map),
                verts = proxy<space>({},verts)] ZS_LAMBDA(int oei) mutable {
                    auto ei = reordered_map[oei];
                    // printf("bd_topos[%d] : %d %d %d %d\n",ei,bd_topos[ei][0],bd_topos[ei][1],bd_topos[ei][2],bd_topos[ei][3]);
                    eles.tuple(dim_c<4>,"inds",oei) = bd_topos[ei].reinterpret_bits(float_c);
                    vec3 x[4] = {};
                    for(int i = 0;i != 4;++i)
                        x[i] = verts.pack(dim_c<3>,"x",bd_topos[ei][i]);

                    mat4 Q = mat4::uniform(0);
                    float C0{};
                    CONSTRAINT::init_IsometricBendingConstraint(x[0],x[1],x[2],x[3],Q,C0);
                    eles.tuple(dim_c<16>,"Q",oei) = Q;
                    eles("C0",oei) = C0;
            });
        }
        // angle on (p2, p3) between triangles (p0, p2, p3) and (p1, p3, p2)
        if(type == "dihedral") {
            constraint->setMeta(CONSTRAINT_KEY,category_c::dihedral_bending_constraint);

            const auto& halfedges = (*source)[ZenoParticles::s_surfHalfEdgeTag];

            zs::Vector<zs::vec<int,4>> bd_topos{quads.get_allocator(),0};
            retrieve_tri_bending_topology(cudaPol,quads,halfedges,bd_topos);

            eles.resize(bd_topos.size());

            topological_coloring(cudaPol,bd_topos,colors);
			sort_topology_by_coloring_tag(cudaPol,colors,reordered_map,color_offset);
            // std::cout << "quads.size() = " << quads.size() << "\t" << "edge_topos.size() = " << edge_topos.size() << std::endl;

            eles.append_channels(cudaPol,{{"inds",4},{"ra",1},{"sign",1}});      

            cudaPol(zs::range(eles.size()),[
                eles = proxy<space>({},eles),
                bd_topos = proxy<space>(bd_topos),
                reordered_map = proxy<space>(reordered_map),
                verts = proxy<space>({},verts)] ZS_LAMBDA(int oei) mutable {
                    auto ei = reordered_map[oei];
                    eles.tuple(dim_c<4>,"inds",oei) = bd_topos[ei].reinterpret_bits(float_c);

                    // printf("topos[%d] : %d %d %d %d\n",oei
                        // ,bd_topos[ei][0]
                        // ,bd_topos[ei][1]
                        // ,bd_topos[ei][2]
                        // ,bd_topos[ei][3]);

                    vec3 x[4] = {};
                    for(int i = 0;i != 4;++i)
                        x[i] = verts.pack(dim_c<3>,"x",bd_topos[ei][i]);

                    float alpha{};
                    float alpha_sign{};
                    CONSTRAINT::init_DihedralBendingConstraint(x[0],x[1],x[2],x[3],alpha,alpha_sign);
                    eles("ra",oei) = alpha;
                    eles("sign",oei) = alpha_sign;
            });      
        }

        if(type == "dihedral_spring") {
            constraint->setMeta(CONSTRAINT_KEY,category_c::dihedral_spring_constraint);
            const auto& halfedges = (*source)[ZenoParticles::s_surfHalfEdgeTag];
            zs::Vector<zs::vec<int,2>> ds_topos{quads.get_allocator(),0};

            retrieve_dihedral_spring_topology(cudaPol,quads,halfedges,ds_topos);

            topological_coloring(cudaPol,ds_topos,colors);
			sort_topology_by_coloring_tag(cudaPol,colors,reordered_map,color_offset);

            eles.resize(ds_topos.size());
            eles.append_channels(cudaPol,{{"inds",2},{"r",1}}); 

            cudaPol(zs::range(eles.size()),[
                verts = proxy<space>({},verts),
                eles = proxy<space>({},eles),
                reordered_map = proxy<space>(reordered_map),
                uniform_stiffness = uniform_stiffness,
                colors = proxy<space>(colors),
                edge_topos = proxy<space>(ds_topos)] ZS_LAMBDA(int oei) mutable {
                    auto ei = reordered_map[oei];
                    eles.tuple(dim_c<2>,"inds",oei) = edge_topos[ei].reinterpret_bits(float_c);
                    vec3 x[2] = {};
                    for(int i = 0;i != 2;++i)
                        x[i] = verts.pack(dim_c<3>,"x",edge_topos[ei][i]);
                    eles("r",oei) = (x[0] - x[1]).norm();
            }); 
        }

        if(type == "kcollision") {
            using bv_t = typename ZenoLinearBvh::lbvh_t::Box;

            constraint->setMeta(CONSTRAINT_KEY,category_c::p_kp_collision_constraint);
            auto target = get_input<ZenoParticles>("target");

            const auto& kverts = target->getParticles();
            ZenoLinearBvh::lbvh_t kbvh{};
            buildBvh(cudaPol,kverts,"px","x","pscale",kbvh);

            zs::bht<int,2,int> csPP{verts.get_allocator(),verts.size()};
            csPP.reset(cudaPol,true);

            cudaPol(zs::range(verts.size()),[
                verts = proxy<space>({},verts),
                kverts = proxy<space>({},kverts),
                kbvh = proxy<space>(kbvh),
                csPP = proxy<space>(csPP)] ZS_LAMBDA(int vi) mutable {
                    auto x = verts.pack(dim_c<3>,"x",vi);
                    auto px = verts.pack(dim_c<3>,"px",vi);
                    auto mx = (x + px) / (T)2.0;
                    auto pscale = verts("pscale",vi);

                    auto radius = (mx - px).norm() + pscale * (T)2.0;
                    auto bv = bv_t{mx - radius,mx + radius};

                    int contact_kvi = -1;
                    T min_contact_time = std::numeric_limits<T>::max();

                    auto process_ccd_collision = [&](int kvi) {
                        auto kpscale = kverts("pscale",kvi);
                        auto kx = kverts.pack(dim_c<3>,"x",kvi);
                        auto pkx = kx;
                        if(kverts.hasProperty("px"))
                            pkx = kverts.pack(dim_c<3>,"px",kvi);

                        auto t = LSL_GEO::ray_ray_intersect(px,x - px,pkx,kx - pkx,(pscale + kpscale) * (T)2);  
                        if(t < min_contact_time) {
                            min_contact_time = t;
                            contact_kvi = kvi;
                        }                      
                    };
                    kbvh.iter_neighbors(bv,process_ccd_collision);

                    if(contact_kvi >= 0) {
                        csPP.insert(vec2i{vi,contact_kvi});
                    }
            });

            eles.resize(csPP.size());
            colors.resize(csPP.size());
            reordered_map.resize(csPP.size());

            eles.append_channels(cudaPol,{{"inds",2}});
            cudaPol(zip(zs::range(csPP.size()),csPP._activeKeys),[
                    eles = proxy<space>({},eles),
                    colors = proxy<space>(colors),
                    reordered_map = proxy<space>(reordered_map)] ZS_LAMBDA(auto ei,const auto& pair) mutable {
                eles.tuple(dim_c<2>,"inds",ei) = pair.reinterpret_bits(float_c);
                colors[ei] = (T)0;
                reordered_map[ei] = ei;
            });

            color_offset.resize(1);
            color_offset.setVal(0);
        }

        // attach to the closest vertex
        if(type == "vertex_attachment") {
            using bv_t = typename ZenoLinearBvh::lbvh_t::Box;

        }

        // attach to the closest point on the surface
        if(type == "surface_point_attachment") {

        }

        // attach to the tetmesh
        if(type == "tetrahedra_attachment") {

        }


        cudaPol(zs::range(eles.size()),[
            eles = proxy<space>({},eles),
            uniform_stiffness = uniform_stiffness,
            colors = proxy<space>(colors),
            // exec_tag,
            reordered_map = proxy<space>(reordered_map)] ZS_LAMBDA(int oei) mutable {
                auto ei = reordered_map[oei];
                eles("lambda",oei) = 0.0;
                eles("stiffness",oei) = uniform_stiffness;
                eles("tclr",oei) = colors[ei];
                // auto 
        });

        constraint->setMeta(CONSTRAINT_COLOR_OFFSET,color_offset);

        // set_output("source",source);
        set_output("constraint",constraint);
    }
};

ZENDEFNODE(MakeSurfaceConstraintTopology, {{
                                {"source"},
                                {"target"},
                                {"float","stiffness","0.5"},
                                {"string","topo_type","stretch"},
                                {"float","rest_scale","1.0"},
                                {"string","pin_point_group_name","groupName"},
                                {"float","binder_max_length","0.1"}
                            },
							{{"constraint"}},
							{ 
                                // {"string","groupID",""},
                            },
							{"PBD"}});




// struct VisualizePBDConstraint : INode {
//     using T = float;
//     using vec3 = zs::vec<T,3>;
//     // using tiles_t = typename ZenoParticles::particles_t;
//     // using dtiles_t = zs::TileVector<T,32>;

//     virtual void apply() override {
//         using namespace zs;
//         using namespace PBD_CONSTRAINT;

//         constexpr auto space = execspace_e::cuda;
//         auto cudaPol = cuda_exec();

//         auto zsparticles = get_input<ZenoParticles>("zsparticles");
//         auto constraints_ptr = get_input<ZenoParticles>("constraints");

//         const auto& geo_verts = zsparticles->getParticles();
//         const auto& constraints = constraints_ptr->getQuadraturePoints();

//         auto tclr_tag = get_param<std::string>("tclrTag");

//         zs::Vector<vec3> cvis{geo_verts.get_allocator(),constraints.getChannelSize("inds") * constraints.size()};
//         zs::Vector<int> cclrs{constraints.get_allocator(),constraints.size()};
//         int cdim = constraints.getChannelSize("inds");
//         cudaPol(zs::range(constraints.size()),[
//             constraints = proxy<space>({},constraints),
//             geo_verts = proxy<space>({},geo_verts),
//             cclrs = proxy<space>(cclrs),
//             tclr_tag = zs::SmallString(tclr_tag),
//             cdim = cdim,
//             cvis = proxy<space>(cvis)] ZS_LAMBDA(int ci) mutable {
//                 // auto cdim = constraints.propertySize("inds");
//                 for(int i = 0;i != cdim;++i) {
//                     auto vi = zs::reinterpret_bits<int>(constraints("inds",i,ci));
//                     cvis[ci * cdim + i] = geo_verts.pack(dim_c<3>,"x",vi);
//                 }
//                 cclrs[ci] = (int)constraints(tclr_tag,ci);
//         });

//         constexpr auto omp_space = execspace_e::openmp;
//         auto ompPol = omp_exec();

//         cvis = cvis.clone({zs::memsrc_e::host});
//         cclrs = cclrs.clone({zs::memsrc_e::host});
//         auto prim = std::make_shared<zeno::PrimitiveObject>();
//         auto& pverts = prim->verts;

//         auto constraint_type = constraints_ptr->readMeta(CONSTRAINT_KEY,wrapt<category_c>{});

//         if(constraint_type == category_c::edge_length_constraint || constraint_type == category_c::dihedral_spring_constraint) {
//             pverts.resize(constraints.size() * 2);
//             auto& plines = prim->lines;
//             plines.resize(constraints.size());
//             auto& tclrs = pverts.add_attr<int>(tclr_tag);
//             auto& ltclrs = plines.add_attr<int>(tclr_tag);

//             ompPol(zs::range(constraints.size()),[
//                 &ltclrs,&pverts,&plines,&tclrs,cvis = proxy<omp_space>(cvis),cclrs = proxy<omp_space>(cclrs)] (int ci) mutable {
//                     pverts[ci * 2 + 0] = cvis[ci * 2 + 0].to_array();
//                     pverts[ci * 2 + 1] = cvis[ci * 2 + 1].to_array();
//                     tclrs[ci * 2 + 0] = cclrs[ci];
//                     tclrs[ci * 2 + 1] = cclrs[ci];
//                     plines[ci] = zeno::vec2i{ci * 2 + 0,ci * 2 + 1};
//                     ltclrs[ci] = cclrs[ci];
//             });
//         }else if(constraint_type == category_c::isometric_bending_constraint || constraint_type == category_c::dihedral_bending_constraint) {
//             pverts.resize(constraints.size() * 2);
//             auto& plines = prim->lines;
//             plines.resize(constraints.size());
//             auto& tclrs = pverts.add_attr<int>(tclr_tag);
//             auto& ltclrs = plines.add_attr<int>(tclr_tag);

//             ompPol(zs::range(constraints.size()),[
//                     &ltclrs,&pverts,&plines,&tclrs,cvis = proxy<omp_space>(cvis),cclrs = proxy<omp_space>(cclrs)] (int ci) mutable {
//                 zeno::vec3f cverts[4] = {};
//                 for(int i = 0;i != 4;++i)
//                     cverts[i] = cvis[ci * 4 + i].to_array();

//                 pverts[ci * 2 + 0] = (cverts[0] + cverts[2] + cverts[3]) / (T)3.0;
//                 pverts[ci * 2 + 1] = (cverts[1] + cverts[2] + cverts[3]) / (T)3.0;
//                 tclrs[ci * 2 + 0] = cclrs[ci];
//                 tclrs[ci * 2 + 1] = cclrs[ci];
//                 ltclrs[ci] = cclrs[ci];

//                 plines[ci] = zeno::vec2i{ci * 2 + 0,ci * 2 + 1};  
//             });
//         }
//         else if(constraint_type == category_c::pt_pin_constraint) {
//             pverts.resize(constraints.size() * 2);
//             auto& plines = prim->lines;
//             plines.resize(constraints.size());
//             auto& tclrs = pverts.add_attr<int>(tclr_tag);
//             auto& ltclrs = plines.add_attr<int>(tclr_tag);


//         }

//         set_output("prim",std::move(prim));
//     }
// };

// ZENDEFNODE(VisualizePBDConstraint, {{{"zsparticles"},{"constraints"}},
// 							{{"prim"}},
// 							{
//                                 {"string","tclrTag","tclrTag"},
//                             },
// 							{"PBD"}});

// solve a specific type of constraint for one iterations
struct XPBDSolve : INode {

    virtual void apply() override {
        using namespace zs;
        using namespace PBD_CONSTRAINT;

        using vec3 = zs::vec<float,3>;
        using vec2i = zs::vec<int,2>;
        using vec3i = zs::vec<int,3>;
        using vec4i = zs::vec<int,4>;
        using mat4 = zs::vec<int,4,4>;

        constexpr auto space = execspace_e::cuda;
        auto cudaPol = cuda_exec();
        constexpr auto exec_tag = wrapv<space>{};

        auto zsparticles = get_input<ZenoParticles>("zsparticles");
        auto constraints = get_input<ZenoParticles>("constraints");

        // auto target = get_input<ZenoParticles>("kbounadry");


        auto dt = get_input2<float>("dt");   
        auto ptag = get_param<std::string>("ptag");

        auto substeps_id = get_input2<int>("substep_id");
        auto nm_substeps = get_input2<int>("nm_substeps");
        auto w = (float)(substeps_id + 1) / (float)nm_substeps;

        // auto current_substep_id = get_input2<int>("substep_id");
        // auto total_substeps = get_input2<int>("total_substeps");

        auto coffsets = constraints->readMeta(CONSTRAINT_COLOR_OFFSET,zs::wrapt<zs::Vector<int>>{});  
        int nm_group = coffsets.size();

        auto& verts = zsparticles->getParticles();
        auto& cquads = constraints->getQuadraturePoints();
        auto category = constraints->readMeta(CONSTRAINT_KEY,wrapt<category_c>{});

        auto target = constraints->readMeta(CONSTRAINT_TARGET,zs::wrapt<ZenoParticles*>{});
        const auto& kverts = target->getParticles();
        const auto& kcells = target->getQuadraturePoints();

        for(int g = 0;g != nm_group;++g) {
            auto coffset = coffsets.getVal(g);
            int group_size = 0;
            if(g == nm_group - 1)
                group_size = cquads.size() - coffsets.getVal(g);
            else
                group_size = coffsets.getVal(g + 1) - coffsets.getVal(g);

            cudaPol(zs::range(group_size),[
                coffset = coffset,
                verts = proxy<space>({},verts),
                category = category,
                dt = dt,
                w = w,
                substeps_id = substeps_id,
                nm_substeps = nm_substeps,
                ptag = zs::SmallString(ptag),
                kverts = proxy<space>({},kverts),
                kcells = proxy<space>({},kcells),
                cquads = proxy<space>({},cquads)] ZS_LAMBDA(int gi) mutable {
                    float s = cquads("stiffness",coffset + gi);
                    float lambda = cquads("lambda",coffset + gi);

                    if(category == category_c::volume_pin_constraint) {
                        auto pair = cquads.pack(dim_c<2>,"inds",coffset + gi,int_c);
                        auto pi = pair[0];
                        auto kti = pair[1];
                        if(kti < 0)
                            return;
                        auto ktet = kcells.pack(dim_c<4>,"inds",kti,int_c);
                        auto bary = cquads.pack(dim_c<4>,"bary",kti);

                        auto ktp = vec3::zeros();
                        for(int i = 0;i != 4;++i) 
                            ktp += kverts.pack(dim_c<3>,"x",ktet[i]) * bary[i];
                        auto pktp = vec3::zeros();
                        for(int i = 0;i != 4;++i) 
                            pktp += kverts.pack(dim_c<3>,"px",ktet[i]) * bary[i];
                        verts.tuple(dim_c<3>,ptag,pi) = (1 - w) * pktp + w * pktp;
                    }

                    if(category == category_c::pt_pin_constraint) {
                        auto pair = cquads.pack(dim_c<2>,"inds",coffset + gi,int_c);
                        if(pair[0] <= 0 || pair[1] <= 0) {
                            printf("invalid pair[%d %d] detected %d %d\n",pair[0],pair[1],coffset,gi);
                            return;
                        }
                        auto pi = pair[0];
                        auto kti = pair[1];
                        if(kti < 0)
                            return;
                        auto ktri = kcells.pack(dim_c<3>,"inds",kti,int_c);
                        auto rd = cquads("rd",coffset + gi);
                        auto bary = cquads.pack(dim_c<3>,"bary",coffset + gi);

                        vec3 kps[3] = {};
                        auto kc = vec3::zeros();
                        for(int i = 0;i != 3;++i){
                            kps[i] = kverts.pack(dim_c<3>,"x",ktri[i]) * w + kverts.pack(dim_c<3>,"px",ktri[i]) * (1 - w);
                            kc += kps[i] * bary[i];
                        }
                            
                        auto knrm = LSL_GEO::facet_normal(kps[0],kps[1],kps[2]);
                        verts.tuple(dim_c<3>,ptag,pi) = kc + knrm * rd;
                    }

                    if(category == category_c::edge_length_constraint || category == category_c::dihedral_spring_constraint) {
                        auto edge = cquads.pack(dim_c<2>,"inds",coffset + gi,int_c);
                        vec3 p0{},p1{};
                        p0 = verts.pack(dim_c<3>,ptag,edge[0]);
                        p1 = verts.pack(dim_c<3>,ptag,edge[1]);
                        float minv0 = verts("minv",edge[0]);
                        float minv1 = verts("minv",edge[1]);
                        float r = cquads("r",coffset + gi);

                        vec3 dp0{},dp1{};
                        if(CONSTRAINT::solve_DistanceConstraint(
                            p0,minv0,
                            p1,minv1,
                            r,
                            s,
                            dt,
                            lambda,
                            dp0,dp1))
                                return;
                        
                        verts.tuple(dim_c<3>,ptag,edge[0]) = p0 + dp0;
                        verts.tuple(dim_c<3>,ptag,edge[1]) = p1 + dp1;
                    }
                    if(category == category_c::isometric_bending_constraint) {
                        auto quad = cquads.pack(dim_c<4>,"inds",coffset + gi,int_c);
                        vec3 p[4] = {};
                        float minv[4] = {};
                        for(int i = 0;i != 4;++i) {
                            p[i] = verts.pack(dim_c<3>,ptag,quad[i]);
                            minv[i] = verts("minv",quad[i]);
                        }

                        auto Q = cquads.pack(dim_c<4,4>,"Q",coffset + gi);
                        auto C0 = cquads("C0",coffset + gi);

                        vec3 dp[4] = {};
                        if(!CONSTRAINT::solve_IsometricBendingConstraint(
                            p[0],minv[0],
                            p[1],minv[1],
                            p[2],minv[2],
                            p[3],minv[3],
                            Q,
                            s,
                            dt,
                            C0,
                            lambda,
                            dp[0],dp[1],dp[2],dp[3]))
                                return;

                        for(int i = 0;i != 4;++i) {
                            // printf("dp[%d][%d] : %f %f %f %f\n",gi,i,s,(float)dp[i][0],(float)dp[i][1],(float)dp[i][2]);
                            verts.tuple(dim_c<3>,ptag,quad[i]) = p[i] + dp[i];
                        }
                    }

                    if(category == category_c::dihedral_bending_constraint) {
                        auto quad = cquads.pack(dim_c<4>,"inds",coffset + gi,int_c);
                        vec3 p[4] = {};
                        float minv[4] = {};
                        for(int i = 0;i != 4;++i) {
                            p[i] = verts.pack(dim_c<3>,ptag,quad[i]);
                            minv[i] = verts("minv",quad[i]);
                        }

                        auto ra = cquads("ra",coffset + gi);
                        auto ras = cquads("sign",coffset + gi);
                        vec3 dp[4] = {};
                        if(!CONSTRAINT::solve_DihedralConstraint(
                            p[0],minv[0],
                            p[1],minv[1],
                            p[2],minv[2],
                            p[3],minv[3],
                            ra,
                            ras,
                            s,
                            dt,
                            lambda,
                            dp[0],dp[1],dp[2],dp[3]))
                                return;
                        for(int i = 0;i != 4;++i) {
                            // printf("dp[%d][%d] : %f %f %f %f\n",gi,i,s,(float)dp[i][0],(float)dp[i][1],(float)dp[i][2]);
                            verts.tuple(dim_c<3>,ptag,quad[i]) = p[i] + dp[i];
                        }                        
                    }
                    cquads("lambda",coffset + gi) = lambda;
            });

        }      

        set_output("constraints",constraints);
        set_output("zsparticles",zsparticles);
        // set_output("target",target);
    };
};

ZENDEFNODE(XPBDSolve, {{{"zsparticles"},
                            {"constraints"},
                            {"int","substep_id","0"},
                            {"int","nm_substeps","1"},
                            // {"target"},
                            // {"string","kptag","x"},
                            {"float","dt","0.5"}},
							{{"zsparticles"},{"constraints"}},
							{{"string","ptag","X"}},
							{"PBD"}});

struct XPBDSolveSmooth : INode {

    virtual void apply() override {
        using namespace zs;
        using namespace PBD_CONSTRAINT;

        using vec3 = zs::vec<float,3>;
        using vec2i = zs::vec<int,2>;
        using vec3i = zs::vec<int,3>;
        using vec4i = zs::vec<int,4>;
        using mat4 = zs::vec<int,4,4>;

        constexpr auto space = execspace_e::cuda;
        auto cudaPol = cuda_exec();
        constexpr auto exec_tag = wrapv<space>{};

        auto zsparticles = get_input<ZenoParticles>("zsparticles");

        auto all_constraints = RETRIEVE_OBJECT_PTRS(ZenoParticles, "all_constraints");
        auto ptag = get_param<std::string>("ptag");
        auto w = get_input2<float>("relaxation_strength");

        auto& verts = zsparticles->getParticles();

        zs::Vector<float> dp_buffer{verts.get_allocator(),verts.size() * 3};
        cudaPol(zs::range(dp_buffer),[]ZS_LAMBDA(auto& v) {v = 0;});
        zs::Vector<int> dp_count{verts.get_allocator(),verts.size()};
        cudaPol(zs::range(dp_count),[]ZS_LAMBDA(auto& c) {c = 0;});

        for(auto &&constraints : all_constraints) {
            const auto& cquads = constraints->getQuadraturePoints();
            auto category = constraints->readMeta(CONSTRAINT_KEY,wrapt<category_c>{});

            cudaPol(zs::range(cquads.size()),[
                verts = proxy<space>({},verts),
                category,
                // dt,
                // w,
                exec_tag,
                dp_buffer = proxy<space>(dp_buffer),
                dp_count = proxy<space>(dp_count),
                ptag = zs::SmallString(ptag),
                cquads = proxy<space>({},cquads)] ZS_LAMBDA(int ci) mutable {
                    float s = cquads("stiffness",ci);
                    float lambda = cquads("lambda",ci);

                    if(category == category_c::dihedral_bending_constraint) {
                        auto quad = cquads.pack(dim_c<4>,"inds",ci,int_c);
                        vec3 p[4] = {};
                        float minv[4] = {};
                        for(int i = 0;i != 4;++i) {
                            p[i] = verts.pack(dim_c<3>,ptag,quad[i]);
                            minv[i] = verts("minv",quad[i]);
                        }

                        auto ra = cquads("ra",ci);
                        auto ras = cquads("sign",ci);
                        vec3 dp[4] = {};
                        if(!CONSTRAINT::solve_DihedralConstraint(
                            p[0],minv[0],
                            p[1],minv[1],
                            p[2],minv[2],
                            p[3],minv[3],
                            ra,
                            ras,
                            (float)1,
                            dp[0],dp[1],dp[2],dp[3]))
                                return;
                        for(int i = 0;i != 4;++i)
                            for(int j = 0;j != 3;++j)
                                atomic_add(exec_tag,&dp_buffer[quad[i] * 3 + j],dp[i][j]);
                        for(int i = 0;i != 4;++i)
                            atomic_add(exec_tag,&dp_count[quad[i]],(int)1);                      
                    }

                    if(category == category_c::edge_length_constraint) {
                        auto edge = cquads.pack(dim_c<2>,"inds",ci,int_c);
                        vec3 p0{},p1{};
                        p0 = verts.pack(dim_c<3>,ptag,edge[0]);
                        p1 = verts.pack(dim_c<3>,ptag,edge[1]);
                        float minv0 = verts("minv",edge[0]);
                        float minv1 = verts("minv",edge[1]);
                        float r = cquads("r",ci);

                        vec3 dp0{},dp1{};
                        if(!CONSTRAINT::solve_DistanceConstraint(
                            p0,minv0,
                            p1,minv1,
                            r,
                            (float)1,
                            dp0,dp1)) {
                        
                            for(int i = 0;i != 3;++i)
                                atomic_add(exec_tag,&dp_buffer[edge[0] * 3 + i],dp0[i]);
                            for(int i = 0;i != 3;++i)
                                atomic_add(exec_tag,&dp_buffer[edge[1] * 3 + i],dp1[i]);

                            atomic_add(exec_tag,&dp_count[edge[0]],(int)1);
                            atomic_add(exec_tag,&dp_count[edge[1]],(int)1);
                        }
                    }
            });
        }      

        cudaPol(zs::range(verts.size()),[
            verts = proxy<space>({},verts),
            ptag = zs::SmallString(ptag),w,
            dp_count = proxy<space>(dp_count),
            dp_buffer = proxy<space>(dp_buffer)] ZS_LAMBDA(int vi) mutable {
                if(dp_count[vi] > 0) {
                    auto dp = w * vec3{dp_buffer[vi * 3 + 0],dp_buffer[vi * 3 + 1],dp_buffer[vi * 3 + 2]};
                    verts.tuple(dim_c<3>,ptag,vi) = verts.pack(dim_c<3>,ptag,vi) + dp / (T)dp_count[vi];
                }
        });

        // set_output("all_constraints",all_constraints);
        set_output("zsparticles",zsparticles);
    };
};

ZENDEFNODE(XPBDSolveSmooth, {{{"zsparticles"},{"all_constraints"},{"float","relaxation_strength","1"}},
							{{"zsparticles"}},
							{{"string","ptag","x"}},
							{"PBD"}});





};
