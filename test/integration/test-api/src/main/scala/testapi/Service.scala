package testapi

import java.nio.ByteBuffer
import cats.implicits._
import cats.effect.Effect
import com.google.flatbuffers.Table
import io.circe._
import io.circe.syntax._
import org.http4s.HttpService
import org.http4s.circe._
import org.http4s.dsl.Http4sDsl
import testapi.flatbuffers._
import scala.util._

class Service[F[_]: Effect] extends Http4sDsl[F] {

  val service: HttpService[F] = {
    HttpService[F] {
      case req @ POST -> Root / flatBufferName =>
        req.as[Array[Byte]].flatMap { bytes =>

          val bb = ByteBuffer.wrap(bytes)

          val json: Try[Option[Json]] =
            Try {
              flatBufferName match {
                case "Simple"     =>
                  val obj = Simple.getRootAsSimple(bb)
                  Json.obj(
                    "n" =>> obj.n,
                    "s" =>> obj.s
                  ).some

                case "FiveFields" =>
                  val obj = FiveFields.getRootAsFiveFields(bb)
                  Json.obj(
                    "n1" =>> obj.n1(),
                    "s1" =>> obj.s1(),
                    "n2" =>> obj.n2(),
                    "s2" =>> obj.s2(),
                    "n3" =>> obj.n3()
                  ).some

                case "ManyTables" =>
                  val obj = ManyTables.getRootAsManyTables(bb)
                  Json.obj(
                    "n" =>> obj.n,
                    "x" =>> inside(obj.x) { x =>
                      Json.obj(
                        "n" =>> x.n,
                        "s" =>> x.s
                      )
                    },
                    "y" =>> inside(obj.y) { y =>
                      Json.obj(
                        "n" =>> y.n,
                        "s" =>> y.s
                      )
                    },
                    "z" =>> inside(obj.z) { z =>
                      Json.obj(
                        "n" =>> z.n,
                        "s" =>> z.s
                      )
                    }
                  ).some

                case "UnionByteBool" =>
                  val obj = UnionByteBool.getRootAsUnionByteBool(bb)
                  Json.obj(
                    "color" =>> Color.name(obj.color),
                    "uni1" =>> readUnion(obj)(_.uni1Type, _.uni1),
                    "uni2" =>> readUnion(obj)(_.uni2Type, _.uni2),
                    "uni3" =>> readUnion(obj)(_.uni3Type, _.uni3),
                    "uni4" =>> readUnion(obj)(_.uni4Type, _.uni4),
                    "boo" =>> obj.boo()
                  ).some

                case "Vectors" =>
                  val obj = Vectors.getRootAsVectors(bb)
                  Json.obj(
                    "x" =>> Json.fromValues((0 until obj.xLength()).map(obj.x).map(_.asJson)),
                    "y" =>> Json.fromValues((0 until obj.yLength()).map(obj.y).map(_.asJson)),
                    "z" =>> Json.fromValues((0 until obj.zLength()).map(obj.z).map(_.asJson))
                  ).some

                case "Structs" =>
                  val obj = Structs.getRootAsStructs(bb)
                  Json.obj(
                    "w" =>> inside(obj.w) { w =>
                      Json.obj(
                        "x" =>> w.x,
                        "y" =>> w.y
                      )
                    },
                    "x" =>> inside(obj.x) { x =>
                      Json.obj(
                        "x" =>> x.x,
                        "y" =>> x.y
                      )
                    },
                    "y" =>> inside(obj.y) { y =>
                      Json.obj(
                        "w" =>> y.w,
                        "x" =>> y.x,
                        "y" =>> y.y,
                        "z" =>> y.z,
                      )
                    },
                    "z" =>> inside(obj.z) { z =>
                      Json.obj(
                        "x" =>> inside(z.x) { x =>
                          Json.obj(
                            "x" =>> x.x,
                            "y" =>> x.y
                          )
                        },
                        "y" =>> inside(z.y) { y =>
                          Json.obj(
                            "w" =>> y.w,
                            "x" =>> y.x,
                            "y" =>> y.y,
                            "z" =>> y.z,
                          )
                        }
                      )
                    }
                  ).some
                case "VectorOfTables" =>
                  val obj = VectorOfTables.getRootAsVectorOfTables(bb)
                  Json.obj(
                    "xs" =>> Json.fromValues((0 until obj.xsLength()).map(obj.xs).map { simple =>
                      Json.obj(
                        "n" =>> simple.n,
                        "s" =>> simple.s
                      )
                    })
                  ).some

                case _ => none
              }
            }

          json.flatMap(j => Try(j.map(_.noSpaces))) match {
            case Success(Some(j)) => Ok(j)
            case Success(None)    => BadRequest("Unrecognized flatbuffer name")
            case Failure(err)     =>
              BadRequest(
                Json.obj(
                  "bytes" =>> bytes.grouped(4).map(_.mkString(",")).toList,
                  "error" =>> err.toString
                ).spaces2
              )
          }
        }
    }
  }

  def inside[A](obj: A)(f: A => Json): Json =
    Option(obj) match {
      case Some(x) => f(x)
      case None    => Json.Null
    }

  implicit class BetterStringOps(value: String) {
    /** Like :=, but checks for nulls. */
    def =>>[A: Encoder](a: A): (String, Json) =
      Option(a) match {
        case Some(x) => (value, x.asJson)
        case None    => (value, Json.Null)
      }
  }

  def readUnion[A <: Table](obj: A)(unionType: A => Byte, union: A => Table => Table): Json =
    unionType(obj) match {
      case U.NONE => "NONE".asJson
      case U.UA =>
        val uni = union(obj)(new UA()).asInstanceOf[UA]
        Json.obj("x" =>> uni.x)
      case U.UB =>
        val uni = union(obj)(new UB()).asInstanceOf[UB]
        Json.obj("y" =>> uni.y)
    }
}

